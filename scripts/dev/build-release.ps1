# ============================================================
# build-release.ps1 —— M5 发布流水线（门禁 → 构建 → 装配 → 尺寸门禁 → 打包）
# 产物：dist/Cloudflare-Deploy-Engine-v<版本>.zip + SHA256.txt + size-report.json
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\build-release.ps1
#       （-SkipTests 跳过测试门禁，仅 CI 二次构建时用）
# 理念门禁（§1.4）：exe ≤ 5MB / templates ≤ 3MB / zip ≤ 10MB，不达标即失败
# ============================================================

param([switch]$SkipTests)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$pkg = Get-Content (Join-Path $Root 'package.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$Version = $pkg.version
$AppName = 'cloudflare-deploy-engine'
$Dist = Join-Path $Root 'dist'
$AppDir = Join-Path $Dist $AppName

Set-Location $Root
Write-Host "==== Cloudflare Deploy Engine v$Version 发布流水线 ===="

function Assert-Gate {
    param([string]$Title, [scriptblock]$Body)
    Write-Host "── $Title ──"
    & $Body
    if ($LASTEXITCODE -ne 0) { throw "门禁失败：$Title（exit=$LASTEXITCODE）" }
}

# ---------- 0. 测试门禁 ----------
if (-not $SkipTests) {
    Assert-Gate '① 语法检查（PSParser）'   { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\syntax-check.ps1') }
    Assert-Gate '② Pester 单元测试'        { & powershell.exe -NoProfile -ExecutionPolicy Bypass -Command ("Invoke-Pester -Script '{0}' -EnableExit" -f (Join-Path $Root 'tests')) }
    Assert-Gate '③ 无凭据扫描'             { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'tests\check-no-secrets.ps1') }
} else {
    Write-Host '（-SkipTests：跳过测试门禁）'
}

# 模板完整性为发布硬门禁（ADR-002），-SkipTests 时仍执行
Assert-Gate '④ 模板完整性（check-build-integrity）' { & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'templates\check-build-integrity.ps1') }

# ---------- 1. 客户端库自愈（js/neutralino.js） ----------
# 官方来源：neu update 从 GitHub Release 下载；网络不可达时从 @neutralinojs/lib 包复制
$clientLib = Join-Path $Root 'js\neutralino.js'
if (-not (Test-Path -LiteralPath $clientLib)) {
    Write-Host 'js/neutralino.js 缺失：尝试 neu update…'
    & npx --no-install @neutralinojs/neu update 2>$null | Out-Null
    if (-not (Test-Path -LiteralPath $clientLib)) {
        $bundled = Join-Path $Root 'node_modules\@neutralinojs\lib\dist\neutralino.js'
        if (Test-Path -LiteralPath $bundled) {
            New-Item -ItemType Directory -Path (Join-Path $Root 'js') -Force | Out-Null
            Copy-Item -LiteralPath $bundled -Destination $clientLib -Force
            Write-Host '已从 @neutralinojs/lib 包恢复客户端库。'
        } else {
            throw '无法获取 neutralino.js 客户端库（网络不可达且无本地包），请先运行 npm install + neu update'
        }
    }
}

# ---------- 2. 同步 resources 并构建 ----------
# 注意：neu 打包器以 .tmp/ 为 asar 暂存区，陈旧内容会被整体卷入 resources.neu
#       （实测：源码解压残留把 resources.neu 撑到 25MB）→ 构建前强制清空。
Remove-Item -LiteralPath (Join-Path $Root '.tmp') -Force -Recurse -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $Root 'resources\js') -Force | Out-Null
Copy-Item (Join-Path $Root 'app\*') (Join-Path $Root 'resources') -Force -Recurse
Copy-Item (Join-Path $Root 'js\*') (Join-Path $Root 'resources\js') -Force

Assert-Gate '⑤ Neutralino 打包（neu build）' {
    & npx --no-install @neutralinojs/neu build
}

# ---------- 3. 装配引擎文件（exe + resources.neu + 引擎真实文件） ----------
# 幂等装配：先清空旧装配再复制（早期 Copy-Item 目录到已存在目标曾产生 scripts\scripts\ 嵌套，
# 顶层残留旧版引擎——zip 内容断言会拦截，但清理是根治）。
foreach ($junk in @('scripts', 'templates', 'plugins.json', 'README.md', '使用说明.md', '使用教程.md', 'start-zeroresidue.cmd')) {
    $p = Join-Path $AppDir $junk
    if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -Recurse }
}
New-Item -ItemType Directory -Path (Join-Path $AppDir 'scripts') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $AppDir 'templates') -Force | Out-Null
Copy-Item -Path (Join-Path $Root 'scripts\*') -Destination (Join-Path $AppDir 'scripts') -Recurse -Force
Copy-Item -Path (Join-Path $Root 'templates\*') -Destination (Join-Path $AppDir 'templates') -Recurse -Force
Copy-Item -LiteralPath (Join-Path $Root 'plugins.json') (Join-Path $AppDir 'plugins.json') -Force
Copy-Item -LiteralPath (Join-Path $Root 'README.md') (Join-Path $AppDir 'README.md') -Force
Copy-Item -LiteralPath (Join-Path $Root '使用说明.md') (Join-Path $AppDir '使用说明.md') -Force
Copy-Item -LiteralPath (Join-Path $Root 'docs\使用教程.md') (Join-Path $AppDir '使用教程.md') -Force
Copy-Item -LiteralPath (Join-Path $Root 'scripts\dev\start-zeroresidue.cmd') (Join-Path $AppDir 'start-zeroresidue.cmd') -Force

# 发布物严禁携带运行时数据：清除 AppDir 内 data/、.tmp/、日志（含 WebView2 缓存/配置/探针残留）
foreach ($junk in @('data', '.tmp')) {
    Remove-Item -LiteralPath (Join-Path $AppDir $junk) -Force -Recurse -ErrorAction SilentlyContinue
}
Get-ChildItem -LiteralPath $AppDir -File | Where-Object { $_.Extension -in @('.log') } | Remove-Item -Force

# ---------- 4. 理念尺寸门禁（§1.4） ----------
$exe = @(Get-ChildItem -LiteralPath $AppDir -Filter '*win_x64.exe' -File)
if ($exe.Count -ne 1) { throw "win_x64 exe 缺失或不止一个：$($exe.Count)" }
$exeMB = [Math]::Round($exe[0].Length / 1MB, 2)
$tplBytes = (Get-ChildItem -LiteralPath (Join-Path $AppDir 'templates') -Recurse -File | Measure-Object Length -Sum).Sum
$tplMB = [Math]::Round($tplBytes / 1MB, 2)
Write-Host "尺寸：win_x64 exe = ${exeMB}MB（上限 5MB）；templates = ${tplMB}MB（上限 3MB）"
if ($exeMB -gt 5) { throw "尺寸门禁失败：exe ${exeMB}MB > 5MB" }
if ($tplMB -gt 3) { throw "尺寸门禁失败：templates ${tplMB}MB > 3MB" }

# ---------- 5. 清理非 Windows 二进制（产品定位 Windows 10/11） ----------
Get-ChildItem -LiteralPath $AppDir -File | Where-Object { $_.Name -match 'linux|mac_' } | Remove-Item -Force

# ---------- 6. 打包 zip（zip ≤ 10MB 门禁） ----------
$zipPath = Join-Path $Dist ("Cloudflare-Deploy-Engine-v{0}.zip" -f $Version)
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
Compress-Archive -Path (Join-Path $AppDir '*') -DestinationPath $zipPath -CompressionLevel Optimal
$zipMB = [Math]::Round((Get-Item -LiteralPath $zipPath).Length / 1MB, 2)
Write-Host "分发物：$zipPath（${zipMB}MB，上限 10MB）"
if ($zipMB -gt 10) { throw "尺寸门禁失败：zip ${zipMB}MB > 10MB" }

# zip 内容断言：① 严禁混入运行时数据（data/ 配置、webview2 缓存、.tmp）
#                ② 严禁嵌套目录（scripts\scripts\、templates\templates\——装配幂等性回归拦截）
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipReader = [System.IO.Compression.ZipFile]::OpenRead($zipPath)
try {
    $leaks = @($zipReader.Entries | Where-Object {
        $_.FullName -match '^(data|\.tmp)/' -or $_.FullName -match 'config\.enc\.json|EBWebView'
    })
    if ($leaks.Count -gt 0) {
        throw "zip 内容断言失败：混入运行时数据！{0}" -f (($leaks.FullName | Select-Object -First 5) -join '；')
    }
    $nested = @($zipReader.Entries | Where-Object { $_.FullName -match '(scripts|templates)[\\/]\1' })
    if ($nested.Count -gt 0) {
        throw "zip 内容断言失败：检测到嵌套目录（装配幂等性回归）！{0}" -f (($nested.FullName | Select-Object -First 3) -join '；')
    }
    # 关键文件存在性（防"旧版残留"回归）
    foreach ($must in @('scripts\market.ps1', 'scripts\plugins\sources\source-gitlab.ps1',
                        'scripts\plugins\targets\target-workers.ps1', 'templates\nav-site\template.json')) {
        if (-not @($zipReader.Entries | Where-Object { $_.FullName -eq $must -or $_.FullName -like ($must + '*') }).Count) {
            throw "zip 内容断言失败：缺少关键文件 $must"
        }
    }
} finally {
    $zipReader.Dispose()
}
Write-Host 'zip 内容断言通过：无运行时数据/无嵌套目录/关键文件齐备。'

# ---------- 7. SHA256 校验文件 ----------
$shaLines = @(
    ('{0}  {1}' -f (Get-FileHash -LiteralPath $exe[0].FullName -Algorithm SHA256).Hash.ToLower(), $exe[0].Name),
    ('{0}  {1}' -f (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower(), (Split-Path -Leaf $zipPath))
)
$shaFile = Join-Path $Dist 'SHA256.txt'
[System.IO.File]::WriteAllLines($shaFile, $shaLines)

# ---------- 8. 尺寸报告 ----------
$report = @{
    version    = $Version
    builtAt    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    winExeMB   = $exeMB
    templatesMB = $tplMB
    zipMB      = $zipMB
    gates      = @{
        exeLe5MB      = ($exeMB -le 5)
        templatesLe3MB = ($tplMB -le 3)
        zipLe10MB     = ($zipMB -le 10)
    }
    zip        = Split-Path -Leaf $zipPath
} | ConvertTo-Json -Depth 5
$reportFile = Join-Path $Dist 'size-report.json'
[System.IO.File]::WriteAllText($reportFile, $report, (New-Object System.Text.UTF8Encoding($false)))

Write-Host ''
Write-Host '==== 发布流水线完成 ===='
Write-Host ("exe: {0}MB | templates: {1}MB | zip: {2}MB | gates: {3}" -f `
    $exeMB, $tplMB, $zipMB, (($report | ConvertFrom-Json).gates.PSObject.Properties.Value -join '/'))
Write-Host "SHA256: $shaFile"