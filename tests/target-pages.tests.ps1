# target-pages 插件测试（网络全模拟）：manifest 构建 + 部署编排 + 删除
# 注意：target-pages 只在文件顶部加载一次，mock 定义在其后
#      （避免 It 块内二次 dot-source 遮蔽 mock，导致真实出网）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')
. (Join-Path $script:Root 'scripts\plugins\targets\target-pages.ps1')

# ---- 模拟 Cloudflare API（拦截 Invoke-Curl，按 URL/方法返回固定 JSON） ----
function Invoke-Curl {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CurlArgs)
    $url = [string]$CurlArgs[$CurlArgs.Count - 1]
    $isPost = @($CurlArgs) -contains 'POST'
    $isDelete = @($CurlArgs) -contains 'DELETE'
    if ($url -match '/user/tokens/verify') { return '{"success":true,"result":{"status":"active"}}' }
    if ($url -match '/storage/kv/namespaces["/]?$') { return '{"success":true,"result":{"id":"ns-1","title":"cde-kv"}}' }
    if ($url -match '/pages/projects/[^/]+/deployments/[^/]+$') { return '{"success":true,"result":{"id":"d1","latest_stage":{"name":"deploy","status":"success"}}}' }
    if ($url -match '/pages/projects/[^/]+/deployments$') {
        if ($isPost) { return '{"success":true,"result":{"id":"deploy-123","url":"https://my-site.pages.dev"}}' }
        return '{"success":true,"result":{"id":"deploy-123"}}'
    }
    if ($url -match '/pages/projects$') {
        if ($isPost) { return '{"success":true,"result":{"id":"p1","name":"my-site"}}' }
        return '{"success":true,"result":[]}'
    }
    if ($url -match '/pages/projects/[^/]+$') {
        if ($isPost) { return '{"success":true,"result":{"id":"p1","name":"my-site"}}' }
        if ($isDelete) { return '{"success":true,"result":{"id":"p1"}}' }
        return '{"success":false,"errors":[{"code":1005,"message":"not found"}]}'
    }
    throw "mock 未覆盖的请求：$url"
}

Describe 'Pages Manifest 构建' {
    It '静态目录生成相对路径哈希清单' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'index.html'), '<h1>hi</h1>')
        New-Item -ItemType Directory -Path (Join-Path $src 'assets') -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'assets\app.js'), 'console.log(1)')
        $m = New-PagesManifest -SourceRoot $src
        $m.Count | Should Be 2
        $m.ContainsKey('/index.html') | Should Be $true
        $m.ContainsKey('/assets/app.js') | Should Be $true
        $m['/index.html'].hash | Should Match '^[0-9a-f]{64}$'
        Remove-Item -LiteralPath $src -Recurse -Force
    }
    It '空格文件名的清单被拒绝' {
        $src = Join-Path $env:TEMP ("site-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $src 'my page.html'), '<h1>hi</h1>')
        { New-PagesManifest -SourceRoot $src } | Should Throw
        Remove-Item -LiteralPath $src -Recurse -Force
    }
}

Describe '部署全流程（API 模拟，非 DryRun）' {
    It '校验 Token → 创建项目 → 直传 → 轮询 → 返回 URL' {
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
        Get-AppConfig -Path $cfgPath -Create | Out-Null   # 空凭证
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