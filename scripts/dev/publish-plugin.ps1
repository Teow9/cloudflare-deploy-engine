# ============================================================
# publish-plugin.ps1 —— 插件发布打包（B1 发布侧，B1）
# 把插件目录打成市场安装包（zip）并生成 registry 条目（含 SHA256）。
# 契约：
#   templates 轴：目录须含 template.json → 整个目录入包
#   其它轴：目录须含 <id>.ps1（handler）→ 递归入包
# 用法：
#   publish-plugin.ps1 -Axis sources -Id my-source -Dir scripts\plugins\sources\my-source.ps1 -Version 1.0.0
#   publish-plugin.ps1 -Axis templates -Id my-tpl -Dir templates\my-tpl -Version 1.0.0
# 产物：dist/publish/<axis>-<id>-v<version>.zip + 打印 registry 条目 JSON
# （发布者把 zip 上传到托管处，把条目并入 market.json 即可）
# ============================================================

param(
    [Parameter(Mandatory = $true)][ValidateSet('sources', 'templates', 'ai', 'targets')][string]$Axis,
    [Parameter(Mandatory = $true)][string]$Id,
    [Parameter(Mandatory = $true)][string]$Dir,
    [string]$Name = '',
    [string]$Version = '1.0.0',
    [string]$Description = ''
)

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if (-not (Test-Path -LiteralPath $Dir)) { throw "源不存在：$Dir" }

$outDir = Join-Path $Root 'dist\publish'
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
$zipPath = Join-Path $outDir ("{0}-{1}-v{2}.zip" -f $Axis, $Id, $Version)
if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }

# 契约校验
if ($Axis -eq 'templates') {
    if (-not (Test-Path -LiteralPath (Join-Path $Dir 'template.json'))) { throw '模板包缺少 template.json' }
} else {
    $handler = Join-Path $Dir "$Id.ps1"
    if (-not (Test-Path -LiteralPath $handler)) { throw "缺少 handler：$handler" }
}

Compress-Archive -Path (Join-Path $Dir '*') -DestinationPath $zipPath -CompressionLevel Optimal
$sha = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLower()
if (-not $Name) { $Name = $Id }
if (-not $Description) { $Description = "由 publish-plugin 生成（$Axis axis）" }

$entry = [PSCustomObject]@{
    axis        = $Axis
    id          = $Id
    name        = $Name
    version     = $Version
    description = $Description
    url         = "https://YOUR-HOST/$Axis-$Id-v$Version.zip"
    sha256      = $sha
}
Write-Host "打包完成：$zipPath"
Write-Host 'registry 条目（并入 market.json 并替换 url 为实际托管地址）：'
Write-Host ($entry | ConvertTo-Json -Depth 4)