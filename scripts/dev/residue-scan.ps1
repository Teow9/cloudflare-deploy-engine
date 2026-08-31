# ============================================================
# residue-scan.ps1 —— 卸载残留扫描（M5 验收：删除文件夹 = 完全卸载）
# 原理：引擎与 Neutralino 运行时均不写注册表 / APPDATA / USERPROFILE，
#       只在本应用目录内写 data/ 与 .tmp/。
# 扫描目标：本目录之外的全部已知副作用位置，输出报告并判定 PASS/FAIL。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\residue-scan.ps1
# ============================================================

$ErrorActionPreference = 'Continue'
$found = @()
Write-Host '==== 卸载残留扫描 ===='

# ① 用户目录（APPDATA / LOCALAPPDATA / USERPROFILE 常见残留名）
foreach ($base in @($env:APPDATA, $env:LOCALAPPDATA, $env:USERPROFILE)) {
    if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
    foreach ($name in @('cloudflare-deploy-engine', 'CloudflareDeployEngine', 'cde-engine', 'com.cde.engine', 'neutralino')) {
        $p = Join-Path $base $name
        if (Test-Path -LiteralPath $p) { $found += $p }
    }
    # APPDATA/LOCALAPPDATA 顶层模糊匹配（仅限本项目命名空间，避免 UnrealEngine 等假阳性）
    foreach ($sub in @(Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue |
                       Where-Object { $_.Name -match 'cloudflare|neutralino|cde' })) {
        $found += $sub.FullName
    }
}

# ② 注册表（HKCU/HKLM 常见位置，读查询）
foreach ($key in @(
        'HKCU:\Software\cloudflare-deploy-engine',
        'HKCU:\Software\cde-engine',
        'HKCU:\Software\com.cde.engine',
        'HKCU:\Software\Neutralinojs',
        'HKLM:\Software\cloudflare-deploy-engine',
        'HKLM:\Software\cde-engine')) {
    if (Test-Path -LiteralPath $key) { $found += $key }
}

# ③ 系统 TEMP 中的本应用痕迹
#    应用只写 cde-body-*.json 临时【文件】（New-TempJsonFile，finally 随用随删），不写目录；
#    TEMP 下 cde-* 目录属单测/调试产物，不算应用残留（另行提示清理）。
if ($env:TEMP) {
    $found += @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^neutralino|cloudflare-deploy' } | ForEach-Object { $_.FullName })
    $testLitter = @(Get-ChildItem -LiteralPath $env:TEMP -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^cde-' } | ForEach-Object { $_.FullName })
    if ($testLitter.Count -gt 0) {
        Write-Host ("提示：TEMP 存在 {0} 个 cde-* 测试/调试目录（非应用残留），可清理：{1}" -f
            $testLitter.Count, ($testLitter | Select-Object -First 3) -join '；')
    }
}

# ④ 本应用目录内的运行时文件（随目录删除 = 无残留；仅列示）
$appRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
Write-Host ("应用目录内运行时数据（随目录删除，不算残留）：{0}" -f
    (@(Get-ChildItem -LiteralPath $appRoot -Directory | Where-Object { $_.Name -in @('data', '.tmp') }).Count) )
if (Test-Path -LiteralPath (Join-Path $appRoot '.tmp\auth_info.json')) {
    Write-Host '注：.tmp/auth_info.json 存在（运行时令牌），随目录删除，无外部残留。'
}

# ---- 报告 ----
$found = @($found | Sort-Object -Unique)

# WebView2 系统缓存白名单（ADR-008）：%APPDATA%\<exe名>\EBWebView 属系统组件托管，
# 直接启动 exe 时的标准行为；用 start-zeroresidue.cmd 启动则完全不出现。
$webview = @($found | Where-Object { $_ -match '\\EBWebView($|\\)' })
$found = @($found | Where-Object { $_ -notin $webview })

Write-Host ''
if ($webview.Count -gt 0) {
    Write-Host ("提示：发现 WebView2 系统缓存（ADR-008，系统组件数据，非应用残留）：{0}" -f ($webview -join '；'))
    Write-Host '      如需系统级零残留，请使用 scripts\dev\start-zeroresidue.cmd 启动（数据收进应用目录）。'
    Write-Host ''
}
if ($found.Count -eq 0) {
    Write-Host 'PASS：未发现任何应用目录之外的残留（WebView2 缓存按系统组件口径豁免并已显式报告）。'
    Write-Host '结论：应用自身零残留（配置/日志/注册表/USERPROFILE 均只在本目录）；删除整个应用文件夹 = 完全卸载（ADR-008 口径）。'
    exit 0
} else {
    Write-Host 'FAIL：发现以下残留（请人工核查来源）：'
    $found | ForEach-Object { Write-Host "  - $_" }
    exit 1
}