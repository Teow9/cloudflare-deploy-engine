# ============================================================
# measure-memory.ps1 —— 理念门禁 A8：部署动作内存实测留档
# 口径（2026-09 实测校准，见《完成度盘点与执行计划.md》A8）：
#   PS 5.1 是引擎宿主（$0 依赖、系统内置），其进程基线即 ~85-95MB WorkingSet，
#   "部署动作内存峰值"按【增量】计量才有意义（宿主基线属运行时本体）。
#   门禁：部署增量 ≤ 40MB（硬）；峰值 ≤ 200MB（失控防线）。
# 输出：基线 / 峰值 / 增量 / PASS-FAIL，留档于测试报告。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\measure-memory.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$cfg = Join-Path $Root 'data\config.enc.json'
$json = '{"site_title":"内存峰值实测"}'
$b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
$scriptPath = '"' + (Join-Path $Root 'scripts\deploy-core.ps1') + '"'
$cfgArg = '"' + $cfg + '"'

function Measure-Peak {
    # 启动给定命令行并采样 WorkingSet 峰值
    param([string]$CmdLine)
    $p = Start-Process powershell.exe -ArgumentList $CmdLine -PassThru -WindowStyle Hidden
    $max = 0L
    $n = 0
    while (-not $p.HasExited) {
        try { $p.Refresh(); if ($p.WorkingSet64 -gt $max) { $max = $p.WorkingSet64 }; $n++ } catch { }
        Start-Sleep -Milliseconds 80
    }
    return @{ peak = $max; samples = $n }
}

# ① 宿主基线：空 powershell.exe
$base = Measure-Peak '-NoProfile -Command "Start-Sleep -Seconds 2"'
$baseMB = [Math]::Round($base.peak / 1MB, 2)

# ② 部署动作（DryRun 全链路：模板展开 + 文件哈希 + 缓存 + 日志/历史）
$cmd = "-NoProfile -ExecutionPolicy Bypass -File $scriptPath -ConfigPath $cfgArg -TemplateId plain -ParamsB64 $b64 -DryRun"
$run = Measure-Peak $cmd
$peakMB = [Math]::Round($run.peak / 1MB, 2)
$deltaMB = [Math]::Round(($run.peak - $base.peak) / 1MB, 2)

Write-Host "采样：基线 ${baseMB}MB（空宿主，$($base.samples) 点）｜ 部署峰值 ${peakMB}MB（$($run.samples) 点）｜ 增量 ${deltaMB}MB"
$okDelta = $deltaMB -le 40
$okPeak = $peakMB -le 200
if ($okDelta -and $okPeak) {
    Write-Host "PASS：增量 ${deltaMB}MB ≤ 40MB 且峰值 ${peakMB}MB ≤ 200MB（§1.4 校准口径）"
    exit 0
}
Write-Host "FAIL：增量 ${deltaMB}MB / 峰值 ${peakMB}MB 超过门禁（增量≤40MB 且峰值≤200MB）"
exit 1