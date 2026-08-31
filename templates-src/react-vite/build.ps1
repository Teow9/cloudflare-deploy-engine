# react-vite 维护者构建：npm ci + vite build → 产物 + template.json 入库 templates/react-vite
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Split-Path -Parent (Split-Path -Parent $src)
$dest = Join-Path $repoRoot 'templates\react-vite'

Push-Location $src
try {
    Write-Host 'npm install ...'
    npm install --no-audit --no-fund 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'npm install 失败' }
    Write-Host 'vite build ...'
    npm run build 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'vite build 失败' }
} finally { Pop-Location }

if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Recurse -Force }
Copy-Item -LiteralPath (Join-Path $src 'dist') -Destination $dest -Recurse -Force
Copy-Item -LiteralPath (Join-Path $src 'template.json') -Destination $dest -Force
Write-Host "react-vite 产物已入库：$dest"