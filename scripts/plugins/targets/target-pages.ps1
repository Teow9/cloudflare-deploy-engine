# ============================================================
# targets/pages 插件 —— Cloudflare Pages 部署目标（ADR-001/006）
# 契约：Invoke-TargetPages -PluginArgs <hashtable>
#   PluginArgs: ConfigPath, SourceRoot, Project, DryRun, KvRequired, EnvVars, Action(deploy|delete)
# 凭证从 config.enc.json 解密读取；任何日志不输出明文 Token。
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')
. (Join-Path $PSScriptRoot '..\..\config-manager.ps1')

function Get-CfApiBase { return 'https://api.cloudflare.com/client/v4' }

function Invoke-CfApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Token = '',
        [string]$JsonBody = '',
        [string[]]$FormArgs = @()
    )
    $curlBase = @('-s', '-X', $Method)
    if ($Token) { $curlBase += @('-H', "Authorization: Bearer $Token") }
    if ($JsonBody) { $curlBase += @('-H', 'Content-Type: application/json', '-d', $JsonBody) }
    $finalArgs = $curlBase + $FormArgs + @($Url)
    return (Invoke-Curl @finalArgs)
}

function Test-CfToken {
    param([Parameter(Mandatory = $true)][string]$Token)
    $resp = Invoke-CfApi -Method 'GET' -Url ((Get-CfApiBase) + '/user/tokens/verify') -Token $Token
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "API Token 校验失败：$resp" }
    return $true
}

function Get-OrCreatePagesProject {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project
    )
    $base = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project"
    $get = Invoke-CfApi -Method 'GET' -Url $base -Token $Token
    $getObj = $get | ConvertFrom-Json
    if ($getObj.success) {
        Write-LogLine -Level INFO -Message "复用 Pages 项目：$Project"
        return $Project
    }
    if (-not $DryRun) {
        $body = @{ name = $Project; production_branch = 'main' } | ConvertTo-Json -Compress
        $resp = Invoke-CfApi -Method 'POST' -Url ((Get-CfApiBase) + "/accounts/$AccountId/pages/projects") -Token $Token -JsonBody $body
        $obj = $resp | ConvertFrom-Json
        if (-not $obj.success) { throw "创建 Pages 项目失败：$resp" }
    }
    Write-LogLine -Level INFO -Message "创建 Pages 项目：$Project"
    return $Project
}

function Get-OrCreateKvNamespace {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [string]$Title = 'cde-kv'
    )
    $listUrl = (Get-CfApiBase) + "/accounts/$AccountId/storage/kv/namespaces"
    $list = Invoke-CfApi -Method 'GET' -Url $listUrl -Token $Token
    $listObj = $list | ConvertFrom-Json
    $found = @($listObj.result | Where-Object { $_.title -eq $Title } | Select-Object -First 1)
    if ($found.Count -gt 0) {
        Write-LogLine -Level INFO -Message "复用 KV 命名空间：$($found[0].id)"
        return $found[0].id
    }
    if ($DryRun) { return 'dryrun-kv-id' }
    $body = @{ title = $Title } | ConvertTo-Json -Compress
    $resp = Invoke-CfApi -Method 'POST' -Url $listUrl -Token $Token -JsonBody $body
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "创建 KV 命名空间失败：$resp" }
    Write-LogLine -Level INFO -Message "创建 KV 命名空间：$($obj.result.id)"
    return $obj.result.id
}

function Update-ProjectBindings {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$KvNamespaceId = '',
        [hashtable]$EnvVars = @{}
    )
    $prod = @{}
    $preview = @{}
    if ($KvNamespaceId) {
        $kv = @{ kv = @{ namespace_id = $KvNamespaceId } }
        $prod.kv_namespaces = $kv
        $preview.kv_namespaces = $kv
    }
    if ($EnvVars.Count -gt 0) {
        $prod.env_vars = $EnvVars
        $preview.env_vars = $EnvVars
    }
    $body = @{ deployment_configs = @{ production = $prod; preview = $preview } } | ConvertTo-Json -Depth 10 -Compress
    $resp = Invoke-CfApi -Method 'PATCH' -Url ((Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project") -Token $Token -JsonBody $body
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "配置 Pages 绑定失败：$resp" }
    Write-LogLine -Level INFO -Message '已配置 KV 绑定与环境变量'
}

function Get-FileMime {
    param([string]$Path)
    $map = @{
        '.html' = 'text/html'; '.htm' = 'text/html'; '.css' = 'text/css'
        '.js' = 'application/javascript'; '.mjs' = 'application/javascript'
        '.json' = 'application/json'; '.svg' = 'image/svg+xml'
        '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'
        '.webp' = 'image/webp'; '.gif' = 'image/gif'; '.ico' = 'image/x-icon'
        '.txt' = 'text/plain'; '.xml' = 'application/xml'; '.pdf' = 'application/pdf'
        '.woff' = 'font/woff'; '.woff2' = 'font/woff2'; '.ttf' = 'font/ttf'
        '.wasm' = 'application/wasm'; '.webmanifest' = 'application/manifest+json'
    }
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    if ($map.ContainsKey($ext)) { return $map[$ext] }
    return 'application/octet-stream'
}

function New-PagesManifest {
    # 静态目录 → Cloudflare 直传 manifest（相对路径 → sha256）
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    if (-not (Test-Path -LiteralPath $SourceRoot)) { throw "待部署目录不存在：$SourceRoot" }
    $manifest = @{}
    foreach ($f in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File)) {
        $rel = '/' + ($f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/') -replace '\\', '/')
        if ($rel -match '[ "]') { throw "文件名包含空格或引号，暂不支持直传：$rel" }
        $manifest[$rel] = @{ hash = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower() }
    }
    if ($manifest.Count -eq 0) { throw "待部署目录为空：$SourceRoot" }
    return $manifest
}

function Push-StaticDeployment {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [Parameter(Mandatory = $true)]$Manifest
    )
    $manifestJson = $manifest | ConvertTo-Json -Compress
    $form = @('-F', ("manifest={0};type=application/json" -f $manifestJson))
    foreach ($rel in $manifest.Keys) {
        $abs = Join-Path $SourceRoot ($rel.TrimStart('/') -replace '/', '\')
        $form += @('-F', ("{0}=@{1};type={2}" -f $rel, $abs, (Get-FileMime -Path $abs)))
    }
    $url = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project/deployments"
    $resp = Invoke-CfApi -Method 'POST' -Url $url -Token $Token -FormArgs $form
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "部署失败：$resp" }
    return $obj.result.id
}

function Push-WorkerDeployment {
    # 面板类模板（显式声明 embedCredentials 并经确认）的单文件直传，MVP 保留不用
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$WorkerJsPath
    )
    $form = @('-F', 'manifest={};type=application/json', '-F', ("_worker.js=@{0};type=application/javascript" -f $WorkerJsPath))
    $url = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project/deployments"
    $resp = Invoke-CfApi -Method 'POST' -Url $url -Token $Token -FormArgs $form
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "部署失败：$resp" }
    return $obj.result.id
}

function Wait-PagesDeployment {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$DeploymentId
    )
    $url = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project/deployments/$DeploymentId"
    $deadline = (Get-Date).AddSeconds(120)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 5
        $resp = Invoke-CfApi -Method 'GET' -Url $url -Token $Token
        $obj = $resp | ConvertFrom-Json
        $st = $obj.result.latest_stage.status
        Write-LogLine -Level INFO -Message "部署状态：$st"
        if ($st -eq 'success') { return $DeploymentId }
        if ($st -eq 'failure' -or $st -eq 'error') { throw "部署失败：$st" }
    }
    throw '部署状态轮询超时（120s）'
}

function Remove-PagesProject {
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project
    )
    $url = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project"
    $resp = Invoke-CfApi -Method 'DELETE' -Url $url -Token $Token
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "删除 Pages 项目失败：$resp" }
    Write-LogLine -Level INFO -Message "已删除 Pages 项目：$Project"
}

function Invoke-TargetPages {
    # 插件契约入口
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('ConfigPath')) { throw 'target-pages: 缺少 ConfigPath' }
    $ConfigPath = $PluginArgs['ConfigPath']
    $DryRun = [bool]$PluginArgs['DryRun']
    $Action = if ($PluginArgs.ContainsKey('Action')) { $PluginArgs['Action'] } else { 'deploy' }
    $cfg = Get-AppConfig -Path $ConfigPath

    if ($Action -eq 'delete') {
        $project = $PluginArgs['Project']
        if (-not $project) { throw 'target-pages: delete 需要 Project' }
        if (-not $DryRun) {
            Remove-PagesProject -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project
        } else {
            Write-LogLine -Level INFO -Message "[DryRun] 将删除 Pages 项目：$project"
        }
        return @{ action = 'delete'; project = $project; dryRun = $DryRun }
    }

    # ---- deploy ----
    $project = $PluginArgs['Project']
    if (-not $project) { throw 'target-pages: 缺少 Project（由 deploy-core 解析）' }
    $SourceRoot = $PluginArgs['SourceRoot']
    if (-not $SourceRoot) { throw 'target-pages: 缺少 SourceRoot' }

    if (-not $DryRun) {
        if (-not $cfg.secrets.apiToken) { throw '未配置 apiToken（config-manager -Verb get -Create 后可设置）' }
        if (-not $cfg.secrets.accountId) { throw '未配置 accountId' }
        Test-CfToken -Token $cfg.secrets.apiToken | Out-Null
    } else {
        Write-LogLine -Level INFO -Message "[DryRun] Token 校验将被跳过"
    }

    if (-not $DryRun) {
        Get-OrCreatePagesProject -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project | Out-Null
    } else {
        Write-LogLine -Level INFO -Message "[DryRun] 将创建/复用 Pages 项目：$project"
    }

    $kvId = ''
    $KvRequired = [bool]$PluginArgs['KvRequired']
    $EnvVars = if ($PluginArgs.ContainsKey('EnvVars')) { $PluginArgs['EnvVars'] } else { @{} }
    if (-not $DryRun) {
        if ($KvRequired) {
            $kvId = Get-OrCreateKvNamespace -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId
        }
        if ($KvRequired -or $EnvVars.Count -gt 0) {
            Update-ProjectBindings -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -KvNamespaceId $kvId -EnvVars $EnvVars
        }
    } elseif ($KvRequired -or $EnvVars.Count -gt 0) {
        Write-LogLine -Level INFO -Message '[DryRun] 将配置 KV 绑定与环境变量'
    }

    $manifest = New-PagesManifest -SourceRoot $SourceRoot
    Write-LogLine -Level INFO -Message "待上传文件数：$($manifest.Count)"

    if ($DryRun) {
        Write-LogLine -Level INFO -Message "[DryRun] 将直传 $($manifest.Count) 个文件到 Pages 项目 $project"
        return @{ action = 'deploy'; project = $project; dryRun = $true; files = $manifest.Count; url = "https://$project.pages.dev" }
    }

    $deployId = Push-StaticDeployment -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -SourceRoot $SourceRoot -Manifest $manifest
    Write-LogLine -Level INFO -Message "部署 ID：$deployId"
    Wait-PagesDeployment -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -DeploymentId $deployId | Out-Null
    return @{ action = 'deploy'; project = $project; url = "https://$project.pages.dev"; deploymentId = $deployId; files = $manifest.Count }
}

# ---------------- 入口（点源加载时不执行） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-TargetPages -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}