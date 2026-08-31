# ============================================================
# bootstrap.ps1 —— 开发环境引导（仅开发者需要，用户不需要）
# 步骤：检查 node/npm → 安装 @neutralinojs/neu（如缺）→ neu update 拉取运行时
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\bootstrap.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)

Write-Host '== Cloudflare Deploy Engine 开发引导 =='

if (-not (Get-Command node -ErrorAction SilentlyContinue)) {
    throw '未找到 node.exe（仅开发需要；最终用户不需要）。请安装 Node.js 20+。'
}
if (-not (Get-Command npm -ErrorAction SilentlyContinue)) {
    throw '未找到 npm。'
}
Write-Host "node: $(& node --version)"

if (-not (Get-Command neu -ErrorAction SilentlyContinue)) {
    Write-Host '安装 @neutralinojs/neu CLI（全局）...'
    npm install -g @neutralinojs/neu
} else {
    Write-Host 'neu CLI 已存在。'
}

Write-Host '拉取 Neutralino 运行时与客户端库（neu update）...'
Push-Location $Root
try {
    npm run neu:update 2>$null
    if ($LASTEXITCODE -ne 0) { & neu update }
}
finally {
    Pop-Location
}

Write-Host ''
Write-Host '完成。下一步：'
Write-Host '  1. 开发运行： neu run'
Write-Host '  2. 引擎冒烟： powershell -NoProfile -ExecutionPolicy Bypass -File scripts\deploy-core.ps1 -ListPlugins'
Write-Host '  3. 单测：     powershell -NoProfile -ExecutionPolicy Bypass -Command "Invoke-Pester -Script @(\"tests/utils.tests.ps1\",\"tests/config-manager.tests.ps1\",\"tests/plugin-manager.tests.ps1\",\"tests/template-manager.tests.ps1\",\"tests/target-pages.tests.ps1\") -EnableExit"'