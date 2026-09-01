# ============================================================
# release.ps1 —— 规范化发布唯一入口（docs/版本管理.md §3）
# 流程：校验 CHANGELOG 版本段 → 创建并推送 tag vX.Y.Z →
#       GitHub API 创建 Release（body=CHANGELOG 段）→ 上传资产
# 资产：dist/Cloudflare-Deploy-Engine-v<版本>.zip + SHA256.txt + size-report.json
# 凭证：环境变量 GH_PAT（git 走一次性 http.extraheader，禁止落盘）
# 幂等：tag/release 已存在时报错（-Force 更新 release body）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File scripts\dev\release.ps1 -Version 0.1.0
#       可选：[-Repo Teow9/cloudflare-deploy-engine] [-Draft] [-Force]
# ============================================================

param(
    [Parameter(Mandatory = $true)][ValidatePattern('^\d+\.\d+\.\d+$')][string]$Version,
    [string]$Repo = 'Teow9/cloudflare-deploy-engine',
    [switch]$Draft,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'   # git 的 stderr 进度在 Stop 下会误抛 NativeCommandError；各步均显式检查 $LASTEXITCODE
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Tag = 'v' + $Version

if (-not $env:GH_PAT) { throw '缺少 GitHub Token：请设置环境变量 GH_PAT（禁止写入文件）' }

# ---------- 0. 本地产物校验 ----------
$dist = Join-Path $Root 'dist'
$zip = Join-Path $dist "Cloudflare-Deploy-Engine-v$Version.zip"
$shaFile = Join-Path $dist 'SHA256.txt'
$report = Join-Path $dist 'size-report.json'
foreach ($f in @($zip, $shaFile, $report)) {
    if (-not (Test-Path -LiteralPath $f)) { throw "发布资产缺失：$f（先运行 build-release.ps1）" }
}
Write-Host "资产就绪：$zip"

# ---------- 1. CHANGELOG 校验与 body 提取（单一事实来源） ----------
$changelog = Join-Path $Root 'CHANGELOG.md'
$content = Get-Content -LiteralPath $changelog -Raw -Encoding UTF8
$pat = '(?s)## \[' + [regex]::Escape($Version) + '\].*?(?=## \[|\[Unreleased\]:|\[[\d\.]+\]:)'
$m = [regex]::Match($content, $pat)
if (-not $m.Success) { throw "CHANGELOG.md 缺少版本段：## [$Version]" }
$body = $m.Value.TrimEnd()

# ---------- 2. git tag 创建与推送 ----------
$git = 'git'
if ($env:GIT_EXE) { $git = $env:GIT_EXE }
Push-Location $Root
try {
    $existing = & $git tag -l $Tag
    if ($existing) {
        if (-not $Force) { throw "本地 tag 已存在：$Tag（-Force 将删除重建，慎用）" }
        & $git tag -d $Tag | Out-Null
    }
    # annotated tag 需要作者身份：注入项目约定身份（不依赖全局 git 配置）
    & $git -c user.name="Cloudflare Deploy Engine" -c user.email="dev@cde.local" tag -a $Tag -m "Release $Tag"
    if ($LASTEXITCODE -ne 0) { throw 'git tag 创建失败' }

    # 一次性认证推送 tag（不落盘）；-Force 重建 tag 时强制推送
    $b64 = [Convert]::ToBase64String([System.Text.Encoding]::ASCII.GetBytes("x-access-token:$env:GH_PAT"))
    $pushed = $false
    for ($i = 1; $i -le 5 -and -not $pushed; $i++) {
        if ($Force) {
            & $git -c http.extraheader="AUTHORIZATION: basic $b64" push --force origin $Tag 2>&1 | Out-Null
        } else {
            & $git -c http.extraheader="AUTHORIZATION: basic $b64" push origin $Tag 2>&1 | Out-Null
        }
        if ($LASTEXITCODE -eq 0) { $pushed = $true }
        else { Write-Host "tag 推送失败（第 $i 次，10s 后重试）"; Start-Sleep -Seconds 10 }
    }
    if (-not $pushed) { throw 'tag 推送失败（网络/凭证）' }
} finally { Pop-Location }
Write-Host "tag 已推送：$Tag"

# ---------- 3. 创建/更新 Release ----------
$apiBase = "https://api.github.com/repos/$Repo"
$hdrAuth = "Authorization: Bearer $env:GH_PAT"
$hdrJson = 'Accept: application/vnd.github+json'
$existsRel = curl.exe -s --noproxy "*" -H $hdrAuth -H $hdrJson "$apiBase/releases/tags/$Tag" | ConvertFrom-Json
$relBody = @{
    tag_name = $Tag
    name     = "v$Version"
    body     = $body
    draft    = [bool]$Draft
    prerelease = $false
} | ConvertTo-Json -Depth 4

if ($existsRel.id) {
    if (-not $Force) { throw "Release 已存在：$Tag（-Force 将更新 body）" }
    # JSON body 走临时文件（PS5.1 原生参数对多行 body 会拆参，复用引擎通行模式）
    $tmpBody = Join-Path $env:TEMP ("cde-rel-body-" + [guid]::NewGuid() + '.json')
    try {
        [System.IO.File]::WriteAllText($tmpBody, $relBody, (New-Object System.Text.UTF8Encoding($false)))
        $rel = curl.exe -s --noproxy "*" -X PATCH -H $hdrAuth -H $hdrJson -H 'Content-Type: application/json' --data-binary ('@' + $tmpBody) "$apiBase/releases/$($existsRel.id)" | ConvertFrom-Json
    } finally { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    Write-Host '更新既有 Release（-Force）'
} else {
    $tmpBody = Join-Path $env:TEMP ("cde-rel-body-" + [guid]::NewGuid() + '.json')
    try {
        [System.IO.File]::WriteAllText($tmpBody, $relBody, (New-Object System.Text.UTF8Encoding($false)))
        $rel = curl.exe -s --noproxy "*" -X POST -H $hdrAuth -H $hdrJson -H 'Content-Type: application/json' --data-binary ('@' + $tmpBody) "$apiBase/releases" | ConvertFrom-Json
    } finally { Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue }
    if (-not $rel.id) { throw "Release 创建失败：$($rel | ConvertTo-Json -Compress)" }
}
Write-Host "Release：$($rel.html_url)"

# ---------- 4. 上传资产（幂等：同名先删） ----------
$assets = @(
    @{ File = $zip;      Name = "Cloudflare-Deploy-Engine-v$Version.zip" },
    @{ File = $shaFile;  Name = 'SHA256.txt' },
    @{ File = $report;   Name = 'size-report.json' }
)
# ---------- 4. 上传资产（幂等：同名先删；端点为 uploads.github.com） ----------
$upBase = "https://uploads.github.com/repos/$Repo/releases/$($rel.id)/assets"
$assets = @(
    @{ File = $zip;      Name = "Cloudflare-Deploy-Engine-v$Version.zip" },
    @{ File = $shaFile;  Name = 'SHA256.txt' },
    @{ File = $report;   Name = 'size-report.json' }
)
foreach ($a in $assets) {
    $list = curl.exe -s --noproxy "*" -H $hdrAuth -H $hdrJson "$apiBase/releases/$($rel.id)/assets?per_page=100" | ConvertFrom-Json
    foreach ($old in @($list)) {
        if ($old.name -eq $a.Name) {
            curl.exe -s --noproxy "*" -X DELETE -H $hdrAuth -H $hdrJson "$apiBase/releases/assets/$($old.id)" | Out-Null
        }
    }
    $up = $null
    for ($i = 1; $i -le 4 -and -not $up; $i++) {
        $raw = curl.exe -s --noproxy "*" -X POST -H $hdrAuth -H "Accept: application/vnd.github+json" `
            -H "Content-Type: application/octet-stream" --data-binary "@$($a.File)" `
            "$upBase?name=$($a.Name)"
        $obj = $raw | ConvertFrom-Json
        if ($obj.id) { $up = $obj } else { Write-Host "资产上传第 $i 次未成功（8s 后重试）"; Start-Sleep -Seconds 8 }
    }
    if (-not $up) { throw "资产上传失败：$($a.Name)（4 次尝试）" }
    Write-Host "资产已上传：$($a.Name)（$($up.size) bytes，sha256=$($up.digest)）"
}

Write-Host ''
Write-Host "===== 发布完成：$Tag ====="
Write-Host "Release: $($rel.html_url)"
Write-Host '请到 Release 页核对 body 与 3 个资产，并按 SHA256 抽查一次下载包。'