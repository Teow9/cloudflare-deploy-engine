# target-workers 插件测试（B3，网络全模拟）
# 注意：target-workers 只在文件顶部加载一次，mock 定义在其后
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')
. (Join-Path $script:Root 'scripts\plugins\targets\target-workers.ps1')

# ---- 模拟 Cloudflare Workers API ----
function Invoke-Curl {
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CurlArgs)
    $argsArr = @($CurlArgs)
    $url = [string]$argsArr[$argsArr.Count - 1]
    if ($url -match '/workers/scripts/[^/]+/subdomain$') {
        return '{"success":true,"result":{"enabled":true,"subdomain":"my-sub"}}'
    }
    if ($url -match '/workers/scripts/[^/]+$') {
        if ($argsArr -contains 'PUT') {
            $at = $argsArr | Where-Object { $_ -is [string] -and $_.StartsWith('@') -and $_.Length -gt 1 } | Select-Object -First 1
            $script:LastUploadedBody = Get-Content -LiteralPath $at.Substring(1) -Raw -Encoding UTF8
            return '{"success":true,"result":{"id":"w1","modified_on":"2026-01-01"}}'
        }
        if ($argsArr -contains 'DELETE') { return '{"success":true,"result":{"id":"w1"}}' }
        return '{"success":false,"errors":[{"code":10000,"message":"not found"}]}'
    }
    throw "mock 未覆盖的请求：$url"
}

function New-TestConfig {
    $p = Join-Path $env:TEMP ("wcfg-" + [guid]::NewGuid() + '.enc.json')
    $cfg = Get-AppConfig -Path $p -Create
    $cfg.secrets.accountId = 'acc-1'
    $cfg.secrets.apiToken = 'tok-1'
    Save-AppConfig -Path $p -Config $cfg
    return $p
}

Describe 'target-workers 部署' {
    It 'PUT 上传 _worker.js 并返回项目与链接' {
        $cfgPath = New-TestConfig
        $src = Join-Path $env:TEMP ("wsrc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'export default { async fetch() { return new Response("ok"); } };' | Set-Content -LiteralPath (Join-Path $src '_worker.js') -Encoding UTF8
        $r = Invoke-TargetWorkers -PluginArgs @{
            ConfigPath = $cfgPath; SourceRoot = $src; Project = 'my-worker'; DryRun = $false
        }
        $r.project | Should Be 'my-worker'
        $r.backend | Should Be 'workers-api'
        $script:LastUploadedBody | Should Match 'async fetch'
        Remove-Item -LiteralPath $cfgPath, $src -Recurse -Force
    }
    It '唯一 .js 可作脚本来源（无 _worker.js）' {
        $cfgPath = New-TestConfig
        $src = Join-Path $env:TEMP ("wsrc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'addEventListener("fetch", () => {});' | Set-Content -LiteralPath (Join-Path $src 'handler.js') -Encoding UTF8
        $r = Invoke-TargetWorkers -PluginArgs @{
            ConfigPath = $cfgPath; SourceRoot = $src; Project = 'w2'; DryRun = $false
        }
        $r.project | Should Be 'w2'
        $script:LastUploadedBody | Should Match 'addEventListener'
        Remove-Item -LiteralPath $cfgPath, $src -Recurse -Force
    }
    It '多个 .js 且无 _worker.js 时报可读错误' {
        $cfgPath = New-TestConfig
        $src = Join-Path $env:TEMP ("wsrc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'a' | Set-Content -LiteralPath (Join-Path $src 'a.js') -Encoding UTF8
        'b' | Set-Content -LiteralPath (Join-Path $src 'b.js') -Encoding UTF8
        { Invoke-TargetWorkers -PluginArgs @{ ConfigPath = $cfgPath; SourceRoot = $src; Project = 'w3'; DryRun = $false } } | Should Throw
        Remove-Item -LiteralPath $cfgPath, $src -Recurse -Force
    }
    It 'DryRun 不产生任何 API 调用' {
        $cfgPath = New-TestConfig
        $src = Join-Path $env:TEMP ("wsrc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $src '_worker.js') -Encoding UTF8
        # mock 对未覆盖请求会 throw；DryRun 若触网则测试失败
        $r = Invoke-TargetWorkers -PluginArgs @{ ConfigPath = $cfgPath; SourceRoot = $src; Project = 'w4'; DryRun = $true }
        $r.dryRun | Should Be $true
        Remove-Item -LiteralPath $cfgPath, $src -Recurse -Force
    }
    It 'WorkerScript 显式指定优先于 SourceRoot' {
        $cfgPath = New-TestConfig
        $js = Join-Path $env:TEMP ("ws-js-" + [guid]::NewGuid() + '.js')
        'export default {};' | Set-Content -LiteralPath $js -Encoding UTF8
        $r = Invoke-TargetWorkers -PluginArgs @{
            ConfigPath = $cfgPath; WorkerScript = $js; Project = 'w5'; DryRun = $false
        }
        $r.project | Should Be 'w5'
        $script:LastUploadedBody | Should Match 'export default'
        Remove-Item -LiteralPath $cfgPath, $js -Force
    }
    It 'EnableSubdomain 在 PUT 后启用 workers.dev 子域' {
        $cfgPath = New-TestConfig
        $src = Join-Path $env:TEMP ("wsrc-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        'x' | Set-Content -LiteralPath (Join-Path $src '_worker.js') -Encoding UTF8
        $r = Invoke-TargetWorkers -PluginArgs @{
            ConfigPath = $cfgPath; SourceRoot = $src; Project = 'w7'; DryRun = $false; EnableSubdomain = $true
        }
        $r.project | Should Be 'w7'
        Remove-Item -LiteralPath $cfgPath, $src -Recurse -Force
    }
}

Describe 'target-workers 删除' {
    It 'delete 动作调用 DELETE 并返回 action' {
        $cfgPath = New-TestConfig
        $r = Invoke-TargetWorkers -PluginArgs @{ ConfigPath = $cfgPath; Project = 'w6'; DryRun = $false; Action = 'delete' }
        $r.action | Should Be 'delete'
        $r.project | Should Be 'w6'
        Remove-Item -LiteralPath $cfgPath -Force
    }
}