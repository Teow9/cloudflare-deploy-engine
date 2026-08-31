# ============================================================
# deploy-core.ps1 —— 通用部署管线（config-driven，ADR-001/007）
# 用法：
#   deploy-core.ps1 -ConfigPath <p> -ListPlugins
#   deploy-core.ps1 -ConfigPath <p> -ListTemplates
#   deploy-core.ps1 -ConfigPath <p> -TemplateId plain -ParamsJson '{"site_title":"我的站"}' -DryRun
#   deploy-core.ps1 -ConfigPath <p> -SourceId local -SourceArgsJson '{"Path":"C:\\site"}' -Project my-site
#   deploy-core.ps1 -ConfigPath <p> -SourceId github -SourceArgsJson '{"Url":"o/r","Ref":"main"}'
# 管线：来源/模板 → 参数展开 → targets.pages 插件上传 → 轮询 → RESULT
# ============================================================

param(
    [string]$ConfigPath = '',
    [string]$TemplateId = '',
    [string]$SourceId = '',
    [string]$SourceArgsJson = '',
    [string]$ParamsJson = '',
    [string]$ParamsB64 = '',
    [string]$SourceArgsB64 = '',
    [string]$Project = '',
    [ValidateSet('native', 'wrangler')][string]$Backend = 'native',
    [switch]$DryRun,
    [switch]$ListPlugins,
    [switch]$ListTemplates,
    [switch]$ListHistory
)

. (Join-Path $PSScriptRoot 'utils.ps1')
. (Join-Path $PSScriptRoot 'config-manager.ps1')
. (Join-Path $PSScriptRoot 'plugin-manager.ps1')
. (Join-Path $PSScriptRoot 'template-manager.ps1')

function Resolve-DeployProject {
    param([string]$ProjectArg, $Config, [string]$DerivedName)
    if ($ProjectArg) { return $ProjectArg }
    if ($Config.settings.pagesProject) { return $Config.settings.pagesProject }
    return (ConvertTo-ProjectSlug -Name $DerivedName)
}

function Invoke-Deploy {
    # UI/CLI 安全通道：Base64(UTF-8) 解码 JSON 参数，免疫命令行引号与编码剥离
    if ($ParamsB64) {
        try { $ParamsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($ParamsB64)) }
        catch { throw 'ParamsB64 不是合法 Base64' }
    }
    if ($SourceArgsB64) {
        try { $SourceArgsJson = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SourceArgsB64)) }
        catch { throw 'SourceArgsB64 不是合法 Base64' }
    }
    $cfg = Get-AppConfig -Path $ConfigPath

    # ---- 1. 解析来源（模板 XOR 自定义来源） ----
    if ($TemplateId -and $SourceId) { throw '-TemplateId 与 -SourceId 不能同时使用' }
    if (-not $TemplateId -and -not $SourceId) { throw '需要 -TemplateId（内置模板）或 -SourceId（自定义来源）' }

    $sourceRoot = ''
    $kvRequired = $false
    $envVars = @{}
    $deployMeta = @{}

    if ($TemplateId) {
        Write-LogLine -Level INFO -Message "使用模板：$TemplateId"
        $meta = Get-TemplateMeta -TemplateId $TemplateId
        $templateDir = Get-TemplatePath -TemplateId $TemplateId
        $overrides = @{}
        if ($ParamsJson) {
            $parsed = $ParamsJson | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $parsed.PSObject.Properties) { $overrides[$p.Name] = $p.Value }
        }
        $merged = Get-TemplateParametersWithDefaults -Meta $meta -Overrides $overrides
        $outDir = Join-Path (Get-CacheDir) ("tpl-$TemplateId-" + (New-Stamp))
        $sourceRoot = Expand-TemplateParams -TemplateDir $templateDir -Params $merged -OutDir $outDir
        $kvRequired = [bool]$meta.cloudflare.kv
        if ($meta.cloudflare.env) { $envVars = @{}; foreach ($p in $meta.cloudflare.env.PSObject.Properties) { $envVars[$p.Name] = $p.Value } }
        $deployMeta = @{ template = $TemplateId; parameters = $merged }
    } else {
        $sourceArgs = @{}
        if ($SourceArgsJson) {
            $parsedSrc = $SourceArgsJson | ConvertFrom-Json -ErrorAction Stop
            foreach ($p in $parsedSrc.PSObject.Properties) { $sourceArgs[$p.Name] = $p.Value }
        }
        $src = Invoke-Plugin -Axis 'sources' -Id $SourceId -PluginArgs $sourceArgs
        $sourceRoot = $src.root
        $deployMeta = @{ source = $SourceId }
    }

    # ---- 2. 项目名解析（param > config > 派生） ----
    $derived = if ($TemplateId) { $TemplateId } else { Split-Path -Leaf $sourceRoot }
    $project = Resolve-DeployProject -ProjectArg $Project -Config $cfg -DerivedName $derived
    Write-LogLine -Level INFO -Message "目标项目：$project"

    # ---- 3. 持久化项目名 + 模板参数记忆（蓝图 §4.4 明文分区） ----
    if ($cfg.settings.pagesProject -ne $project) {
        $cfg.settings.pagesProject = $project
        Save-AppConfig -Path $ConfigPath -Config $cfg
    }
    if ($TemplateId -and -not $DryRun) {
        $cfg.settings.lastTemplate = $TemplateId
        $cfg.settings.lastTemplateParams = $merged
        Save-AppConfig -Path $ConfigPath -Config $cfg
    }

    # ---- 4. 调用 targets/pages 插件 ----
    $targetArgs = @{
        ConfigPath = $ConfigPath
        SourceRoot = $sourceRoot
        Project    = $project
        DryRun     = [bool]$DryRun
        KvRequired = $kvRequired
        EnvVars    = $envVars
        Backend    = $Backend
        Action     = 'deploy'
    }
    $result = Invoke-Plugin -Axis 'targets' -Id 'pages' -PluginArgs $targetArgs

    return @{
        deployed = (-not $DryRun)
        dryRun   = [bool]$DryRun
        project  = $result.project
        url      = $result.url
        files    = $result.files
        backend  = $result.backend
        servingOk    = $result.servingOk
        attempts     = $result.attempts
        probeCode    = $result.probeCode
        deploymentId = $result.deploymentId
        deploymentShortId = $result.deploymentShortId
        meta     = $deployMeta
    }
}

# ---------------- 入口 ----------------
try {
    if (-not $ConfigPath) { $ConfigPath = (Join-Path (Get-DataDir) 'config.enc.json') }
    if ($ListPlugins) {
        Write-Result @{ plugins = @(Get-PluginList) }
        exit 0
    }
    if ($ListTemplates) {
        Write-Result @{ templates = @(Get-TemplateList) }
        exit 0
    }
    if ($ListHistory) {
        Write-Result @{ history = @(Read-DeployHistory) }
        exit 0
    }

    # ---- 运行锁 + 日志落盘 + 部署历史（蓝图 §4.2） ----
    Lock-Deploy
    Clear-StaleCache
    $logStamp = New-Stamp
    $logDir = Join-Path (Get-DataDir) 'logs'
    $logFile = Join-Path $logDir ("deploy-$logStamp.log")
    Set-ActiveLogFile -Path $logFile
    $historyProject = ''
    try {
        $result = Invoke-Deploy
        $historyProject = $result.project
        if (-not $DryRun) {
            $m = $result.meta
            Add-DeployHistory -Project $result.project -Source $m.source -Template $m.template `
                -Parameters $m.parameters -Url $result.url -Status 'ok' `
                -ServingOk ([bool]$result.servingOk) -Attempts ([int]$result.attempts) `
                -Backend $result.backend -DeploymentId $result.deploymentId -LogFile $logFile
        }
        Write-Result $result
    } catch {
        if (-not $DryRun) {
            Add-DeployHistory -Project $historyProject -Status 'failed' -LogFile $logFile
        }
        throw
    } finally {
        Unlock-Deploy
    }
} catch {
    Write-LogLine -Level ERROR -Message $_.Exception.Message
    Write-Result @{ error = $_.Exception.Message }
    exit 1
}