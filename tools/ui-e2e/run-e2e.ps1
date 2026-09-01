# ============================================================
# run-e2e.ps1 —— GUI 端到端部署测试编排（tools/ui-e2e）
# 用法（工作区根执行）：
#   powershell -NoProfile -ExecutionPolicy Bypass -File tools\ui-e2e\run-e2e.ps1 `
#     -Zip dist\Cloudflare-Deploy-Engine-v0.1.1.zip -WorkDir ..\..\_ui-e2e `
#     -Account <accountId> -Project cde-e2e-ui<stamp>
#   （API Token 经环境变量 CDE_E2E_TOKEN 传入，本脚本不落盘）
# 流程：清残留 → 全新解压 → 启动 exe（CDP 开端口）→ node 驱动 → 清理进程
# ============================================================
param(
    [string]$Zip = '',
    [string]$WorkDir = '',
    [string]$Account = '',
    [string]$Project = '',
    [string]$Port = '9345'
)
$ErrorActionPreference = 'Continue'
if (-not $Zip) { $Zip = Join-Path (Split-Path -Parent $PSScriptRoot) '..\..\dist\Cloudflare-Deploy-Engine-v0.1.1.zip' }
if (-not $WorkDir) { $WorkDir = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) '_ui-e2e' }
$Zip = (Resolve-Path $Zip).Path

# 清残留进程（本测试目录的 WebView2 + 应用 exe）
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like ('*' + [regex]::Escape($WorkDir) + '*') -or $_.CommandLine -like '*ui-e2e*' } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name cloudflare-deploy-engine-win_x64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 800

# 全新解压
Remove-Item $WorkDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path (Join-Path $WorkDir 'app') -Force | Out-Null
New-Item -ItemType Directory -Path (Join-Path $WorkDir 'shots') -Force | Out-Null
Expand-Archive -Path $Zip -DestinationPath (Join-Path $WorkDir 'app') -Force
Write-Host ('zip extracted: ' + (Split-Path -Leaf $Zip))

# 启动 exe（WEBVIEW2 远程调试端口：仅供驱动探测，与用户双击一致）
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=$Port"
$exe = Start-Process -FilePath (Join-Path $WorkDir 'app\cloudflare-deploy-engine-win_x64.exe') `
    -WorkingDirectory (Join-Path $WorkDir 'app') -PassThru
Write-Host ('exe pid=' + $exe.Id)

# 驱动环境（凭证仅环境变量）
$env:CDE_E2E_BASE = $WorkDir
$env:CDE_E2E_CDP_PORT = $Port
$env:CDE_E2E_ACCOUNT = $Account
$env:CDE_E2E_PROJECT = $Project
$env:CDE_E2E_EMAIL = 'tester@cde.local'

$driver = Join-Path $PSScriptRoot 'deploy-flow.mjs'
$np = Start-Process -FilePath node -ArgumentList ('"' + $driver + '"') -WorkingDirectory $WorkDir `
    -RedirectStandardOutput (Join-Path $WorkDir 'node.out') -RedirectStandardError (Join-Path $WorkDir 'node.err') `
    -Wait -PassThru -NoNewWindow
Write-Host ('driver exit=' + $np.ExitCode)

# 清理
Remove-Item Env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS -ErrorAction SilentlyContinue
Remove-Item Env:CDE_E2E_BASE, Env:CDE_E2E_CDP_PORT, Env:CDE_E2E_ACCOUNT, Env:CDE_E2E_PROJECT, Env:CDE_E2E_EMAIL -ErrorAction SilentlyContinue
Get-Process -Name cloudflare-deploy-engine-win_x64 -ErrorAction SilentlyContinue | Stop-Process -Force
Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like ('*' + [regex]::Escape($WorkDir) + '*') } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }

if (Test-Path (Join-Path $WorkDir 'results.json')) {
    Write-Host '===== E2E 结果摘要 ====='
    $r = Get-Content (Join-Path $WorkDir 'results.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    Write-Host ('ok=' + $r.ok)
    foreach ($s in $r.steps) { Write-Host ('- ' + $s.step + ' => ' + ([string]$s.value).Substring(0, [Math]::Min(180, ([string]$s.value).Length))) }
} else {
    Write-Host '结果文件缺失（驱动未完成）'
    if (Test-Path (Join-Path $WorkDir 'node.err')) { Get-Content (Join-Path $WorkDir 'node.err') | Select-Object -First 10 }
}