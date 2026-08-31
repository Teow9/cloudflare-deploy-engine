# build-all.ps1 —— 模板源码构建/入库（templates-src/ → templates/，仅维护者使用）
# 规则：子目录含 build.ps1（构建型模板，如 react-vite）→ 执行之（自行负责入库）；
#       否则视为静态模板 → 整目录拷贝入库（含 template.json）。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File templates-src\build-all.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent $scriptRoot

foreach ($t in @(Get-ChildItem -LiteralPath $scriptRoot -Directory)) {
    $id = $t.Name
    $dest = Join-Path $repoRoot "templates\$id"
    $build = Join-Path $t.FullName 'build.ps1'
    if (Test-Path -LiteralPath $build) {
        Write-Host "构建型模板：$id ..."
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $build
        if ($LASTEXITCODE -ne 0) { throw "$id 构建失败（exit=$LASTEXITCODE）" }
    } else {
        Write-Host "静态模板入库：$id"
        if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
        Copy-Item -LiteralPath $t.FullName -Destination $dest -Recurse -Force
    }
}
Write-Host 'build-all 完成。请运行 templates\check-build-integrity.ps1 验证。'