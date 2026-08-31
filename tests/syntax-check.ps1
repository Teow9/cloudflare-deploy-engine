# ============================================================
# syntax-check.ps1 —— 全库语法检查（PSParser，兼容 Windows PowerShell 5.1）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\syntax-check.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$files = @(Get-ChildItem -LiteralPath (Join-Path $Root 'scripts') -Recurse -Filter '*.ps1' -File) +
         @(Get-ChildItem -LiteralPath (Join-Path $Root 'tests') -Filter '*.ps1' -File)

$failures = @()
foreach ($f in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
    foreach ($e in $errors) {
        $failures += ("{0}({1},{2}): {3}" -f $f.FullName, $e.Extent.StartLineNumber, $e.Extent.StartColumnNumber, $e.Message)
    }
}

if ($failures.Count -gt 0) {
    Write-Host '== 语法错误 =='
    $failures | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "语法检查通过：$($files.Count) 个脚本"
exit 0