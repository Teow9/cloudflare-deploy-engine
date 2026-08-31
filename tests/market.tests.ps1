# market.tests.ps1 —— 插件市场（B1）：registry / install / uninstall / 校验 / 内置保护
# 注意：install/uninstall 会写真实 plugins.json → 全程 try/finally 备份恢复；
#       下载/暂存走 CDE_DATA_DIR 临时目录。
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')
. (Join-Path $script:Root 'scripts\plugin-manager.ps1')
. (Join-Path $script:Root 'scripts\market.ps1')

$script:OldDataDir = $env:CDE_DATA_DIR
$script:TestData = Join-Path $env:TEMP ("cde-market-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $script:TestData -Force | Out-Null
$env:CDE_DATA_DIR = $script:TestData

# plugins.json 备份（market 测试唯一会改的仓库文件）
$script:RegPath = Join-Path $script:Root 'plugins.json'
$script:RegBackup = Get-Content -LiteralPath $script:RegPath -Raw -Encoding UTF8

function Restore-Registry {
    [System.IO.File]::WriteAllText($script:RegPath, $script:RegBackup, (New-Object System.Text.UTF8Encoding($false)))
    $script:PluginRegistryCache = $null   # market 修改 plugins.json 后清分发缓存
}
function New-FixDir {
    # 造市场安装包：templates 样例 + sources 样例
    param([string]$Tag)
    $dir = Join-Path $script:TestData "fix-$Tag"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    return $dir
}

# ---------- fixtures ----------
$tplDir = New-FixDir 'tpl'
@'
{ "id": "market-test-tpl", "name": "测试模板", "version": "1.0.0", "description": "市场测试模板",
  "cloudflare": { "kv": false, "env": {} }, "parameters": [], "ai": { "keywords": [] } }
'@ | Set-Content -LiteralPath (Join-Path $tplDir 'template.json') -Encoding UTF8
'<h1>market tpl</h1>' | Set-Content -LiteralPath (Join-Path $tplDir 'index.html') -Encoding UTF8
$tplZip = Join-Path $script:TestData 'market-test-tpl.zip'
Compress-Archive -Path (Join-Path $tplDir '*') -DestinationPath $tplZip -Force

$srcDir = New-FixDir 'src'
@'
# market-test-src —— 市场测试来源插件
. (Join-Path $PSScriptRoot '..\..\utils.ps1')
function Invoke-SourceMarketTestSrc {
    param([hashtable]$PluginArgs = @{})
    return @{ root = (Join-Path (Get-CacheDir) 'market-test-src'); source = 'market-test-src' }
}
'@ | Set-Content -LiteralPath (Join-Path $srcDir 'market-test-src.ps1') -Encoding UTF8
$srcZip = Join-Path $script:TestData 'market-test-src.zip'
Compress-Archive -Path (Join-Path $srcDir '*') -DestinationPath $srcZip -Force

$tplSha = (Get-FileHash -LiteralPath $tplZip -Algorithm SHA256).Hash.ToLower()
$srcSha = (Get-FileHash -LiteralPath $srcZip -Algorithm SHA256).Hash.ToLower()
$registry = [PSCustomObject]@{ plugins = @(
    [PSCustomObject]@{ axis = 'templates'; id = 'market-test-tpl'; name = '测试模板'; version = '1.0.0'; description = '市场测试'; url = $tplZip; sha256 = $tplSha },
    [PSCustomObject]@{ axis = 'sources'; id = 'market-test-src'; name = '测试来源'; version = '1.0.0'; description = '市场测试'; url = $srcZip; sha256 = $srcSha }
) }
$regFile = Join-Path $script:TestData 'market.json'
[System.IO.File]::WriteAllText($regFile, ($registry | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))

Describe '市场 registry（本地 JSON 源）' {
    It '解析出插件数组' {
        $reg = Read-MarketRegistry -Url $regFile
        $reg.plugins.Count | Should Be 2
        $reg.plugins[0].axis | Should Be 'templates'
    }
    It 'CLI registry 输出 RESULT（冒烟）' {
        $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:Root 'scripts\market.ps1') -ConfigPath (Join-Path $script:TestData 'c.enc.json') -Verb registry -MarketUrl $regFile 2>&1
        $r = $out | Where-Object { $_ -match '^RESULT\|' } | Select-Object -First 1
        $j = ($r -replace '^RESULT\|', '') | ConvertFrom-Json
        $j.plugins.Count | Should Be 2
    }
}

Describe '市场安装（templates 轴）' {
    It '落位 templates/<id> 并注册 plugins.json，可 invoke' {
        try {
            $r = Install-MarketPlugin -Axis templates -Id 'market-test-tpl' -Url $tplZip -Sha256 $tplSha
            $r.id | Should Be 'market-test-tpl'
            $script:PluginRegistryCache = $null
            (Test-Path -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl\template.json')) | Should Be $true
            $meta = Invoke-Plugin -Axis templates -Id 'market-test-tpl' -PluginArgs @{}
            $meta.id | Should Be 'market-test-tpl'
        } finally { Restore-Registry; Remove-Item -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl') -Force -Recurse -ErrorAction SilentlyContinue }
    }
    It 'SHA256 不符被拒绝且不落位' {
        try {
            { Install-MarketPlugin -Axis templates -Id 'market-test-tpl' -Url $tplZip -Sha256 ('0' * 64) } | Should Throw
            (Test-Path -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl')) | Should Be $false
        } finally { Restore-Registry; Remove-Item -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl') -Force -Recurse -ErrorAction SilentlyContinue }
    }
    It '重复安装被拒；-Force 可覆盖' {
        try {
            $null = Install-MarketPlugin -Axis templates -Id 'market-test-tpl' -Url $tplZip -Sha256 $tplSha
            { Install-MarketPlugin -Axis templates -Id 'market-test-tpl' -Url $tplZip -Sha256 $tplSha } | Should Throw
            $null = Install-MarketPlugin -Axis templates -Id 'market-test-tpl' -Url $tplZip -Sha256 $tplSha -Force
            (Test-Path -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl\index.html')) | Should Be $true
        } finally { Restore-Registry; Remove-Item -LiteralPath (Join-Path $script:Root 'templates\market-test-tpl') -Force -Recurse -ErrorAction SilentlyContinue }
    }
}

Describe '市场安装（sources 轴）+ 卸载' {
    It 'handler 落位并可通过插件分发调用' {
        try {
            $null = Install-MarketPlugin -Axis sources -Id 'market-test-src' -Url $srcZip -Sha256 $srcSha
            $script:PluginRegistryCache = $null
            (Test-Path -LiteralPath (Join-Path $script:Root 'scripts\plugins\sources\market-test-src.ps1')) | Should Be $true
            $r = Invoke-Plugin -Axis sources -Id 'market-test-src' -PluginArgs @{}
            $r.source | Should Be 'market-test-src'
        } finally { Restore-Registry; Remove-Item -LiteralPath (Join-Path $script:Root 'scripts\plugins\sources\market-test-src.ps1') -Force -ErrorAction SilentlyContinue }
    }
    It 'uninstall 注销注册并删除文件' {
        try {
            $null = Install-MarketPlugin -Axis sources -Id 'market-test-src' -Url $srcZip -Sha256 $srcSha
            $r = Uninstall-MarketPlugin -Id 'market-test-src'
            $r.action | Should Be 'uninstall'
            (Test-Path -LiteralPath (Join-Path $script:Root 'scripts\plugins\sources\market-test-src.ps1')) | Should Be $false
            $reg = Get-Content -LiteralPath $script:RegPath -Raw -Encoding UTF8 | ConvertFrom-Json
            @($reg.sources | Where-Object { $_.id -eq 'market-test-src' }).Count | Should Be 0
        } finally { Restore-Registry; Remove-Item -LiteralPath (Join-Path $script:Root 'scripts\plugins\sources\market-test-src.ps1') -Force -ErrorAction SilentlyContinue }
    }
    It '内置插件不可卸载' {
        { Uninstall-MarketPlugin -Id 'plain' } | Should Throw
        { Uninstall-MarketPlugin -Id 'github' } | Should Throw
    }
    It '未安装插件卸载报错' {
        { Uninstall-MarketPlugin -Id 'market-not-exist' } | Should Throw
    }
}

# 恢复环境与注册表
Restore-Registry
if ($null -eq $script:OldDataDir) { Remove-Item Env:CDE_DATA_DIR -ErrorAction SilentlyContinue }
else { $env:CDE_DATA_DIR = $script:OldDataDir }
Remove-Item -LiteralPath $script:TestData -Force -Recurse -ErrorAction SilentlyContinue