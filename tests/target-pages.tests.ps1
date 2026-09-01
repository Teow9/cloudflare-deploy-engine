# target-pages 插件测试（网络全模拟）：资产两段式上传 + 部署编排 + 删除
# 注意：target-pages 只在文件顶部加载一次，mock 定义在其后
#      （避免 It 块内二次 dot-source 遮蔽 mock，导致真实出网）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')
. (Join-Path $script:Root 'scripts\plugins\targets\target-pages.ps1')

# ---- 模拟 Cloudflare API（拦截 Invoke-Curl，按 URL 分派） ----
function Invoke-Curl {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CurlArgs)
    $argsArr = @($CurlArgs)
    $url = [string]$argsArr[$argsArr.Count - 1]

    if ($url -match '/user/tokens/verify') { return '{"success":true,"result":{"status":"active"}}' }
    if ($url -match '/upload-token$') { return '{"success":true,"result":{"jwt":"mock-pages-jwt"}}' }
    if ($url -match '/pages/assets/check-missing$') {
        # 回显请求体中的 hashes（读取 --data-binary @file 内容）
        $at = $argsArr | Where-Object { $_ -is [string] -and $_.StartsWith('@') -and $_.Length -gt 1 } | Select-Object -First 1
        $hashes = @('mock-unknown-hash')
        if ($at) {
            $body = (Get-Content -LiteralPath $at.Substring(1) -Raw -Encoding UTF8 | ConvertFrom-Json)
            $hashes = @($body.hashes)
        }
        return (@{ success = $true; result = $hashes } | ConvertTo-Json -Compress)
    }
    if ($url -match '/pages/assets/(upload|upsert-hashes)$') { return '{"success":true,"result":{}}' }
    if ($url -match '/storage/kv/namespaces["/]?$') { return '{"success":true,"result":{"id":"ns-1","title":"cde-kv"}}' }
    if ($url -match '/pages/projects/[^/]+/deployments/[^/]+$') { return '{"success":true,"result":{"id":"d1","latest_stage":{"name":"deploy","status":"success"}}}' }
    if ($url -match '/pages/projects/[^/]+/deployments$') {
        if ($argsArr -contains 'POST') { return '{"success":true,"result":{"id":"deploy-123","url":"https://my-site.pages.dev"}}' }
        return '{"success":true,"result":{"id":"deploy-123"}}'
    }
    if ($url -match '/pages/projects$') {
        if ($argsArr -contains 'POST') {
            # 创建项目：登记到 mock 状态（后续 GET 可返回真实 subdomain）
            $at = $argsArr | Where-Object { $_ -is [string] -and $_.StartsWith('@') -and $_.Length -gt 1 } | Select-Object -First 1
            $name = 'my-site'
            if ($at) { $body = (Get-Content -LiteralPath $at.Substring(1) -Raw -Encoding UTF8 | ConvertFrom-Json); if ($body.name) { $name = $body.name } }
            $script:MockProjects[$name] = $true
            return '{"success":true,"result":{"id":"p1","name":"my-site"}}'
        }
        return '{"success":true,"result":[]}'
    }
    if ($url -match '/pages/projects/([^/]+)$') {
        $name = [regex]::Match($url, '/pages/projects/([^/]+)$').Groups[1].Value
        if ($argsArr -contains 'POST') { $script:MockProjects[$name] = $true; return '{"success":true,"result":{"id":"p1","name":"my-site"}}' }
        if ($argsArr -contains 'DELETE') { $script:MockProjects.Remove($name) | Out-Null; return '{"success":true,"result":{"id":"p1"}}' }
        if ($script:MockProjects.ContainsKey($name)) {
            # 创建后 GET 返回真实 subdomain（v0.1.3：结果 URL / 探针改用平台实际分配子域）
            return (@{ success = $true; result = @{ name = $name; subdomain = "$name.pages.dev" } } | ConvertTo-Json -Compress)
        }
        return '{"success":false,"errors":[{"code":1005,"message":"not found"}]}'
    }
    throw "mock 未覆盖的请求：$url"
}
$script:MockProjects = @{}

# 探针 mock：测试内不触网，直接视为存活
function Test-DeploymentUrl {
    param([Parameter(Mandatory = $true)][string]$Url)
    return '200'
}

Describe '文件记录与 manifest（官方格式）' {
    It '生成 rel/hash/size/contentType 记录' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'index.html'), '<h1>hi</h1>')
        New-Item -ItemType Directory -Path (Join-Path $src 'assets') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'assets\app.js'), 'console.log(1)')
        $recs = @(New-FileRecords -SourceRoot $src)
        $recs.Count | Should Be 2
        ($recs | Where-Object { $_.rel -eq 'index.html' }).hash | Should Match '^[0-9a-f]{64}$'
        ($recs | Where-Object { $_.rel -eq 'index.html' }).size | Should Be 11
        ($recs | Where-Object { $_.rel -eq 'assets/app.js' }).contentType | Should Be 'application/javascript'
        Remove-Item -LiteralPath $src -Recurse -Force
    }
    It 'manifest 为路径→hash 字符串映射' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'index.html'), '<h1>hi</h1>')
        $m = New-StaticManifest -Records @(New-FileRecords -SourceRoot $src)
        $m.Count | Should Be 1
        $m['/index.html'] | Should Match '^[0-9a-f]{64}$'
        Remove-Item -LiteralPath $src -Recurse -Force
    }
    It '空格文件名的记录被拒绝' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'my page.html'), '<h1>hi</h1>')
        { New-FileRecords -SourceRoot $src } | Should Throw
        Remove-Item -LiteralPath $src -Recurse -Force
    }
}

Describe '部署全流程（API 模拟，官方两段式）' {
    It '校验 Token → 项目 → assets 上传 → 部署 → 返回 URL' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'index.html'), '<h1>hi</h1>')
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $cfgPath -Create | Out-Null
        Set-SecretField -Path $cfgPath -Field accountId -Value 'acc-1'
        Set-SecretField -Path $cfgPath -Field apiToken -Value 'cfut_test'

        $r = Invoke-TargetPages -PluginArgs @{
            ConfigPath = $cfgPath; SourceRoot = $src; Project = 'my-site'
            DryRun = $false; Action = 'deploy'; KvRequired = $false
        }
        $r.project | Should Be 'my-site'
        $r.url | Should Be 'https://my-site.pages.dev'
        $r.files | Should Be 1
        Remove-Item -LiteralPath $src, $cfgPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'DryRun 不产生任何 API 调用（无副作用，空凭证亦可）' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'index.html'), '<h1>hi</h1>')
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $cfgPath -Create | Out-Null
        $r = Invoke-TargetPages -PluginArgs @{
            ConfigPath = $cfgPath; SourceRoot = $src; Project = 'my-site'
            DryRun = $true; Action = 'deploy'
        }
        $r.dryRun | Should Be $true
        $r.url | Should Be 'https://my-site.pages.dev'
        Remove-Item -LiteralPath $src, $cfgPath -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe '删除项目（API 模拟）' {
    It 'delete 动作调用 DELETE 并返回 action' {
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $cfgPath -Create | Out-Null
        Set-SecretField -Path $cfgPath -Field apiToken -Value 'cfut_test'
        Set-SecretField -Path $cfgPath -Field accountId -Value 'acc-1'
        $r = Invoke-TargetPages -PluginArgs @{ ConfigPath = $cfgPath; Project = 'my-site'; DryRun = $false; Action = 'delete' }
        $r.action | Should Be 'delete'
        $r.project | Should Be 'my-site'
        Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
    }
    It '未设置 Token 时 delete 抛出可读错误' {
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $cfgPath -Create | Out-Null
        { Invoke-TargetPages -PluginArgs @{ ConfigPath = $cfgPath; Project = 'my-site'; DryRun = $false; Action = 'delete' } } | Should Throw
        Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
    }
}