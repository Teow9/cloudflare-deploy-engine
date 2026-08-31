# ============================================================
# targets/workers 插件 —— Cloudflare Workers 单一脚本部署（B3）
# 契约：Invoke-TargetWorkers -PluginArgs <hashtable>
#   PluginArgs: ConfigPath, SourceRoot(或 WorkerScript 直接指定), Project(=script 名),
#               DryRun, Action(deploy|delete)
# 脚本来源：SourceRoot 下 _worker.js 优先；否则唯一 .js；WorkerScript 显式覆盖。
# 凭证要求：Workers Scripts:Edit（Pages:Edit 不覆盖 → 真实调用预期 403，属权限边界）。
# API：PUT /accounts/{a}/workers/scripts/{name}（body=JS 原文）
#      可选启用于域：POST .../scripts/{name}/subdomain {"enabled":true}
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')
. (Join-Path $PSScriptRoot '..\..\config-manager.ps1')

function Get-CfApiBase {
    if ($env:CDE_API_BASE) { return $env:CDE_API_BASE }
    return 'https://api.cloudflare.com/client/v4'
}

function Invoke-CfApi {
    param(
        [Parameter(Mandatory = $true)][string]$Method,
        [Parameter(Mandatory = $true)][string]$Url,
        [string]$Token = '',
        [string]$JsonBody = '',
        [string]$RawBody = '',
        [string]$ContentType = 'application/json'
    )
    $curlBase = @('-s', '-X', $Method)
    if ($Token) { $curlBase += @('-H', "Authorization: Bearer $Token") }
    $tmpBody = ''
    if ($RawBody) {
        # JS / 文本原文直传（不经 JSON 转义）：临时文件 + --data-binary
        $tmpBody = Join-Path $env:TEMP ("cde-body-" + [guid]::NewGuid().ToString('N') + '.js')
        Write-Utf8File -Path $tmpBody -Text $RawBody
        $curlBase += @('-H', "Content-Type: $ContentType", '--data-binary', ('@' + $tmpBody))
    } elseif ($JsonBody) {
        $tmpBody = New-TempJsonFile -Json $JsonBody
        $curlBase += @('-H', 'Content-Type: application/json', '--data-binary', ('@' + $tmpBody))
    }
    try {
        $resp = Invoke-Curl @curlBase @($Url)
        if ($resp -notmatch '^\s*[\{\[]') {
            throw "API 返回非 JSON（疑似平台 5xx 故障窗口）：$($resp.Substring(0, [Math]::Min(120, [string]$resp.Length)))"
        }
        return $resp
    } finally {
        if ($tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    }
}

function Resolve-WorkerScript {
    # 从 SourceRoot 定位脚本：_worker.js 优先 → 唯一 .js → 抛错
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    $candidate = Join-Path $SourceRoot '_worker.js'
    if (Test-Path -LiteralPath $candidate) { return $candidate }
    $js = @(Get-ChildItem -LiteralPath $SourceRoot -File -Filter '*.js' -ErrorAction SilentlyContinue)
    if ($js.Count -eq 1) { return $js[0].FullName }
    if ($js.Count -gt 1) {
        throw "SourceRoot 下存在多个 .js（$_($js.Count) 个），请使用 -WorkerScript 或调整目录（仅 _worker.js 会优先）"
    }
    throw "SourceRoot 中没有 _worker.js 或唯一 .js：$SourceRoot"
}

function Invoke-TargetWorkers {
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('ConfigPath')) { throw 'target-workers: 缺少 ConfigPath' }
    $ConfigPath = $PluginArgs['ConfigPath']
    $DryRun = [bool]$PluginArgs['DryRun']
    $Action = if ($PluginArgs.ContainsKey('Action')) { $PluginArgs['Action'] } else { 'deploy' }
    $Project = $PluginArgs['Project']
    if (-not $Project) { throw 'target-workers: 缺少 Project（脚本名）' }
    $cfg = Get-AppConfig -Path $ConfigPath

    if ($Action -eq 'delete') {
        if (-not $DryRun) {
            $resp = Invoke-CfApi -Method 'DELETE' -Url ((Get-CfApiBase) + "/accounts/$($cfg.secrets.accountId)/workers/scripts/$Project") -Token $cfg.secrets.apiToken
            $obj = $resp | ConvertFrom-Json
            if (-not $obj.success) { throw "删除 Worker 失败：$resp" }
            Write-LogLine -Level INFO -Message "已删除 Worker：$Project"
        } else {
            Write-LogLine -Level INFO -Message "[DryRun] 将删除 Worker：$Project"
        }
        return @{ action = 'delete'; project = $Project; dryRun = $DryRun }
    }

    # ---- deploy ----
    $scriptPath = ''
    if ($PluginArgs.ContainsKey('WorkerScript') -and $PluginArgs['WorkerScript']) {
        $scriptPath = [string]$PluginArgs['WorkerScript']
        if (-not (Test-Path -LiteralPath $scriptPath)) { throw "WorkerScript 不存在：$scriptPath" }
    } else {
        if (-not $PluginArgs['SourceRoot']) { throw 'target-workers: 缺少 SourceRoot（或 WorkerScript）' }
        $scriptPath = Resolve-WorkerScript -SourceRoot ([string]$PluginArgs['SourceRoot'])
    }
    Write-LogLine -Level INFO -Message "Worker 脚本：$scriptPath → $Project"

    if (-not $DryRun) {
        if (-not $cfg.secrets.apiToken) { throw '未配置 apiToken' }
        if (-not $cfg.secrets.accountId) { throw '未配置 accountId' }
        $content = Read-Utf8File -Path $scriptPath
        $resp = Invoke-CfApi -Method 'PUT' -Url ((Get-CfApiBase) + "/accounts/$($cfg.secrets.accountId)/workers/scripts/$Project") `
            -Token $cfg.secrets.apiToken -RawBody $content -ContentType 'application/javascript'
        $obj = $resp | ConvertFrom-Json
        if (-not $obj.success) { throw "Worker 上传失败：$resp" }
        Write-LogLine -Level INFO -Message 'Worker 脚本已上传'
        # 可选：启用 workers.dev 子域（EnableSubdomain=$true，配合默认子域访问）
        if ($PluginArgs.ContainsKey('EnableSubdomain') -and $PluginArgs['EnableSubdomain']) {
            $subResp = Invoke-CfApi -Method 'PUT' -Url ((Get-CfApiBase) + "/accounts/$($cfg.secrets.accountId)/workers/scripts/$Project/subdomain") `
                -Token $cfg.secrets.apiToken -JsonBody '{"enabled":true}'
            $subObj = $subResp | ConvertFrom-Json
            if (-not $subObj.success) { throw "启用于域失败：$subResp" }
            Write-LogLine -Level INFO -Message "已启用 workers.dev 子域：$Project"
        }
    } else {
        Write-LogLine -Level INFO -Message "[DryRun] 将 PUT 上传 Worker 脚本：$Project"
    }
    return @{
        action = 'deploy'
        project = $Project
        backend = 'workers-api'
        files = 1
        url = "https://$Project.<account-subdomain>.workers.dev（绑定子域后生效）"
        dryRun = $DryRun
        servingOk = $null
    }
}

# ---------------- 入口（点源加载时不执行） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-TargetWorkers -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}