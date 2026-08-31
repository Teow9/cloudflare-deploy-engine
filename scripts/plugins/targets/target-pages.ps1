# ============================================================
# targets/pages 插件 —— Cloudflare Pages 部署目标（ADR-001/006）
# 契约：Invoke-TargetPages -PluginArgs <hashtable>
#   PluginArgs: ConfigPath, SourceRoot, Project, DryRun, KvRequired, EnvVars, Action(deploy|delete)
# 凭证从 config.enc.json 解密读取；任何日志不输出明文 Token。
# 上传流程（对齐 wrangler 官方实现，2026 现代 Pages 资产体系）：
#   upload-token → assets/check-missing → assets/upload(base64) →
#   assets/upsert-hashes → deployments(multipart: manifest+branch)
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')
. (Join-Path $PSScriptRoot '..\..\config-manager.ps1')

function Get-CfApiBase {
    # 调试/取证：允许 CDE_API_BASE 环境变量覆盖（生产默认官方端点）
    if ($env:CDE_API_BASE) { return $env:CDE_API_BASE }
    return 'https://api.cloudflare.com/client/v4'
}

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
    $tmpBody = ''
    if ($JsonBody) {
        # PS 5.1 会把 -d 参数里的双引号剥掉 → 必须走临时文件
        $tmpBody = New-TempJsonFile -Json $JsonBody
        $curlBase += @('-H', 'Content-Type: application/json', '--data-binary', ('@' + $tmpBody))
    }
    $finalArgs = $curlBase + $FormArgs + @($Url)
    try {
        $resp = Invoke-Curl @finalArgs
        # 平台间歇性故障防护：非 JSON 响应（HTML 错误页/空）立即报错，交由上层重试
        if ($resp -notmatch '^\s*[\{\[]') {
            throw "API 返回非 JSON 响应（疑似平台 5xx 故障窗口）：$($resp.Substring(0, [Math]::Min(120, [string]$resp.Length)))"
        }
        return $resp
    } finally {
        if ($tmpBody) { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    }
}

function Test-CfToken {
    # Cloudflare: GET /user/tokens/verify（POST 不被该 URI 接受）
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

function New-FileRecords {
    # SourceRoot → 文件记录（rel/hash/size/contentType），供 assets 上传与 manifest
    param([Parameter(Mandatory = $true)][string]$SourceRoot)
    if (-not (Test-Path -LiteralPath $SourceRoot)) { throw "待部署目录不存在：$SourceRoot" }
    $records = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $SourceRoot -Recurse -File)) {
        $rel = $f.FullName.Substring($SourceRoot.Length).TrimStart('\', '/') -replace '\\', '/'
        if ($rel -match '[ "]') { throw "文件名包含空格或引号，暂不支持直传：$rel" }
        $records += [PSCustomObject]@{
            rel         = $rel
            path        = $f.FullName
            hash        = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLower()
            size        = $f.Length
            contentType = Get-FileMime -Path $f.FullName
        }
    }
    if ($records.Count -eq 0) { throw "待部署目录为空：$SourceRoot" }
    return $records
}

function Get-PagesUploadJwt {
    # 官方两段式上传第一步：换取 Pages 资产服务 JWT
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project
    )
    $resp = Invoke-CfApi -Method 'GET' -Url ((Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project/upload-token") -Token $Token
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success -or -not $obj.result.jwt) { throw "获取 upload-token 失败：$resp" }
    return [string]$obj.result.jwt
}

function Invoke-PagesAssetsJson {
    # 资产服务调用（Bearer JWT + JSON body 走临时文件）
    param(
        [Parameter(Mandatory = $true)][string]$ApiPath,
        [Parameter(Mandatory = $true)][string]$Jwt,
        [Parameter(Mandatory = $true)][string]$BodyJson
    )
    $tmp = New-TempJsonFile -Json $BodyJson
    try {
        $resp = Invoke-Curl -s -X POST -H "Authorization: Bearer $Jwt" -H 'Content-Type: application/json' --data-binary ('@' + $tmp) ((Get-CfApiBase) + $ApiPath)
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
    if ($resp -notmatch '^\s*[\{\[]') {
        throw "资产服务返回非 JSON（疑似平台 5xx 故障窗口 $ApiPath）：$($resp.Substring(0, [Math]::Min(120, [string]$resp.Length)))"
    }
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "资产服务调用失败 $ApiPath：$resp" }
    return $obj.result
}

function Send-PagesAssets {
    # 官方两段式上传第二~四步：check-missing → upload(base64) → upsert-hashes
    # -ForceUpload：跳过 check-missing 全量重传（坏窗口期资产修复用）
    param(
        [Parameter(Mandatory = $true)][string]$Jwt,
        [Parameter(Mandatory = $true)][array]$Records,
        [switch]$ForceUpload
    )
    $allHashes = @($Records | ForEach-Object { $_.hash })

    $missing = @()
    if ($ForceUpload) {
        Write-LogLine -Level INFO -Message "强制重传模式：跳过 check-missing，全量上传"
        $missing = $allHashes
    } else {
        try {
            $missing = @(Invoke-PagesAssetsJson -ApiPath '/pages/assets/check-missing' -Jwt $Jwt -BodyJson (@{ hashes = $allHashes } | ConvertTo-Json -Compress))
        } catch {
            Write-LogLine -Level WARN -Message "check-missing 失败（$($_.Exception.Message)），回退全量上传"
            $missing = $allHashes
        }
    }

    $toUpload = @($Records | Where-Object { $missing -contains $_.hash })
    if ($toUpload.Count -gt 0) {
        $payload = @()
        foreach ($r in $toUpload) {
            $payload += @{
                key      = $r.hash
                value    = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($r.path))
                metadata = @{ contentType = $r.contentType }
                base64   = $true
            }
        }
        $null = Invoke-PagesAssetsJson -ApiPath '/pages/assets/upload' -Jwt $Jwt -BodyJson ($payload | ConvertTo-Json -Depth 8 -Compress)
        Write-LogLine -Level INFO -Message "资产上传完成：$($toUpload.Count) 个"
    } else {
        Write-LogLine -Level INFO -Message "资产已存在（无缺失 hash），跳过上传"
    }

    try {
        $null = Invoke-PagesAssetsJson -ApiPath '/pages/assets/upsert-hashes' -Jwt $Jwt -BodyJson (@{ hashes = $allHashes } | ConvertTo-Json -Compress)
    } catch {
        Write-LogLine -Level WARN -Message 'upsert-hashes 失败（可忽略，仅影响下次上传加速）'
    }
    return $Records
}

function New-StaticManifest {
    # 官方 manifest 格式：{ "/index.html": "<sha256hex>" }（字符串值）
    param([Parameter(Mandatory = $true)][array]$Records)
    $m = @{}
    foreach ($r in $Records) { $m['/' + $r.rel] = $r.hash }
    return $m
}

function Push-StaticDeployment {
    # 现代 Pages 两段式部署：资产入库 + manifest/branch 建部署（无文件部件）
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$AccountId,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$SourceRoot,
        [string]$Branch = 'main',
        [switch]$ForceUpload
    )
    $records = @(New-FileRecords -SourceRoot $SourceRoot)
    $jwt = Get-PagesUploadJwt -Token $Token -AccountId $AccountId -Project $Project
    $records = @(Send-PagesAssets -Jwt $jwt -Records $records -ForceUpload:$ForceUpload)

    $manifest = New-StaticManifest -Records $records
    $tmpManifest = New-TempJsonFile -Json ($manifest | ConvertTo-Json -Compress)
    try {
        # 注意：manifest 部件不能带 Content-Type（实测 CF 会忽略带
        # application/json 类型的 manifest 字段 → 部署永不激活 → 500）。
        # wrangler 原样：multipart 纯文本部件。
        $form = @(
            '-F', ("manifest=<{0}" -f $tmpManifest),
            '-F', ("branch={0}" -f $Branch)
        )
        $url = (Get-CfApiBase) + "/accounts/$AccountId/pages/projects/$Project/deployments"
        $resp = Invoke-CfApi -Method 'POST' -Url $url -Token $Token -FormArgs $form
    } finally {
        Remove-Item -LiteralPath $tmpManifest -Force -ErrorAction SilentlyContinue
    }
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.success) { throw "部署失败：$resp" }
    return $obj.result.id
}

function Find-Wrangler {
    # wrangler 后端（已知可 100% 激活 Pages 服务层）：
    # 优先 WRANGLER_PATH 环境变量，其次 PATH 上的 wrangler
    if ($env:WRANGLER_PATH -and (Test-Path -LiteralPath $env:WRANGLER_PATH)) { return $env:WRANGLER_PATH }
    $cmd = Get-Command wrangler -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return ''
}

function Invoke-WranglerDeploy {
    # 官方客户端部署（Backend=wrangler 时使用；需用户机器装有 wrangler）
    param(
        [Parameter(Mandatory = $true)][string]$Token,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$SourceRoot
    )
    $exe = Find-Wrangler
    if (-not $exe) { throw '未找到 wrangler（请安装并加入 PATH，或设置 WRANGLER_PATH）；可改用默认 native 后端' }
    $logFile = Join-Path (Get-CacheDir) ("wrangler-" + (New-Stamp) + '.log')
    $oldToken = $env:CLOUDFLARE_API_TOKEN
    $env:CLOUDFLARE_API_TOKEN = $Token
    try {
        & $exe 'pages' 'deploy' $SourceRoot '--project-name' $Project '--branch' 'main' *> $logFile
        $exit = $LASTEXITCODE
    } finally {
        if ($oldToken) { $env:CLOUDFLARE_API_TOKEN = $oldToken } else { Remove-Item Env:CLOUDFLARE_API_TOKEN -Force -ErrorAction SilentlyContinue }
    }
    $log = Get-Content -LiteralPath $logFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($exit -ne 0) { throw "wrangler 部署失败（exit=$exit）：$(([string]$log).Substring(0, [Math]::Min(600, [string]$log.Length)))" }
    $m = [regex]::Match($log, 'https://([0-9a-f]{8})\.[a-z0-9\-]+\.pages\.dev')
    if (-not $m.Success) { throw "wrangler 部署完成但未解析到部署 URL：$log" }
    return $m.Groups[1].Value
}

function Test-DeploymentUrl {
    # 部署后存活探针：返回 HTTP 状态码（000=连接失败）
    param([Parameter(Mandatory = $true)][string]$Url)
    $code = & curl.exe --noproxy "*" -s -o NUL -w '%{http_code}' --connect-timeout 8 $Url 2>$null
    if (-not $code) { return '000' }
    return [string]$code
}

function Push-WorkerDeployment {
    # 旧式单 Worker 直传（manifest={}+_worker.js）。注意：现代 Pages（并入 Workers）
    # 已迁至资产体系，本函数保留仅为兼容研究与面板类模板（ADR-001 特例），MVP 不使用
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

    $records = @(New-FileRecords -SourceRoot $SourceRoot)
    Write-LogLine -Level INFO -Message "待上传文件数：$($records.Count)"

    if ($DryRun) {
        Write-LogLine -Level INFO -Message "[DryRun] 将创建/复用 Pages 项目：$project"
        Write-LogLine -Level INFO -Message "[DryRun] 将经 assets 两段式上传 $($records.Count) 个文件并部署（manifest+branch）"
        return @{ action = 'deploy'; project = $project; dryRun = $true; files = $records.Count; url = "https://$project.pages.dev" }
    }

    Get-OrCreatePagesProject -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project | Out-Null

    $kvId = ''
    $KvRequired = [bool]$PluginArgs['KvRequired']
    $EnvVars = if ($PluginArgs.ContainsKey('EnvVars')) { $PluginArgs['EnvVars'] } else { @{} }
    if ($KvRequired -or $EnvVars.Count -gt 0) {
        if ($KvRequired) {
            $kvId = Get-OrCreateKvNamespace -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId
        }
        Update-ProjectBindings -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -KvNamespaceId $kvId -EnvVars $EnvVars
    }

    # ---- 后端分发 + 重试循环（平台有间歇性资产故障窗口，wrangler 同款韧性） ----
    $Backend = if ($PluginArgs.ContainsKey('Backend')) { $PluginArgs['Backend'] } else { 'native' }
    $result = @{ action = 'deploy'; project = $project; backend = $Backend; files = $records.Count; url = "https://$project.pages.dev" }

    $servingOk = $false
    $attempts = 0
    $lastProbeCode = '000'
    while (-not $servingOk -and $attempts -lt 3) {
        $attempts++
        Write-LogLine -Level INFO -Message "部署尝试 $attempts/3（backend=$Backend）"
        try {
            if ($Backend -eq 'wrangler') {
                $shortId = Invoke-WranglerDeploy -Token $cfg.secrets.apiToken -Project $project -SourceRoot $SourceRoot
                $result.deploymentShortId = $shortId
                $probeUrl = "https://$shortId.$project.pages.dev"
                Write-LogLine -Level INFO -Message "wrangler 部署完成（short_id=$shortId）"
            } else {
                # 第 2 次起强制重传：坏窗口期"已存在但损坏"的资产需要覆盖
                $deployId = Push-StaticDeployment -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -SourceRoot $SourceRoot -ForceUpload:($attempts -gt 1)
                Write-LogLine -Level INFO -Message "部署 ID：$deployId"
                Wait-PagesDeployment -Token $cfg.secrets.apiToken -AccountId $cfg.secrets.accountId -Project $project -DeploymentId $deployId | Out-Null
                $result.deploymentId = $deployId
                $probeUrl = "https://$($deployId.Substring(0, 8)).$project.pages.dev"
            }
        } catch {
            Write-LogLine -Level WARN -Message "第 $attempts 次部署调用失败（$($_.Exception.Message)）"
            if ($attempts -lt 3) {
                Start-Sleep -Seconds 5
                continue
            }
            throw
        }

        Start-Sleep -Seconds 3
        $lastProbeCode = Test-DeploymentUrl -Url $probeUrl
        if ($lastProbeCode -match '^[23]\d\d$') {
            $servingOk = $true
        } elseif ($attempts -lt 3) {
            Write-LogLine -Level WARN -Message "第 $attempts 次部署未在边缘激活（HTTP $lastProbeCode），5 秒后重试（强制重传）"
            Start-Sleep -Seconds 5
        }
    }

    $result.servingOk = $servingOk
    $result.probeCode = $lastProbeCode
    $result.attempts = $attempts
    if ($servingOk) {
        Write-LogLine -Level INFO -Message "部署存活探针通过（HTTP $lastProbeCode，第 $attempts 次尝试）"
    } else {
        Write-LogLine -Level WARN -Message "3 次尝试后部署仍未在边缘激活（HTTP $lastProbeCode）。属平台侧故障窗口/激活问题：可稍后重试或改用 Backend=wrangler / 控制台上传。"
    }
    return $result
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