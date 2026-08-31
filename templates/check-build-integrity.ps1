# ============================================================
# check-build-integrity.ps1 —— 模板完整性门禁（ADR-002 / 计划 M3）
# 检查项（对齐 docs/模板开发指南.md §五）：
#   ① 每个注册模板目录存在 template.json 且可解析
#   ② 每模板至少 1 个部署文件
#   ③ 无 node_modules / .env / 构建源码泄漏
#   ④ templates/ 总尺寸 ≤ 3MB（理念门禁 §1.4）
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File templates\check-build-integrity.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$TemplatesRoot = $PSScriptRoot   # 脚本位于 templates/ 内 → 模板根即脚本所在目录
$Root = Split-Path -Parent $TemplatesRoot
$errors = @()

# 注册表优先（plugins.json templates 段），另扫目录兜底找出未注册模板
$regTemplates = @()
$regPath = Join-Path $Root 'plugins.json'
if (Test-Path -LiteralPath $regPath) {
    $reg = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $regTemplates = @($reg.templates | ForEach-Object { $_.path })
}
$dirs = @(Get-ChildItem -LiteralPath $TemplatesRoot -Directory | ForEach-Object { 'templates/' + $_.Name })
$allDirs = @($regTemplates + $dirs | Sort-Object -Unique)

if ($allDirs.Count -eq 0) { Write-Host 'FAIL：没有找到任何模板目录'; exit 1 }

foreach ($rel in $allDirs) {
    $dir = Join-Path $Root $rel
    $name = Split-Path -Leaf $dir
    $metaPath = Join-Path $dir 'template.json'
    if (-not (Test-Path -LiteralPath $metaPath)) {
        $errors += "模板目录缺少 template.json：$rel"
        continue
    }
    try {
        $null = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        $errors += "template.json 解析失败：$rel（$($_.Exception.Message)）"
    }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File | Where-Object { $_.Name -ne 'template.json' })
    if ($files.Count -eq 0) { $errors += "模板无部署文件：$rel" }
    foreach ($bad in @('node_modules', '.env')) {
        $hit = Get-ChildItem -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -eq $bad }
        if ($hit) { $errors += "模板含禁用内容（$bad）：$rel" }
    }
}

$tplBytes = (Get-ChildItem -LiteralPath $TemplatesRoot -Recurse -File | Measure-Object Length -Sum).Sum
$tplMB = [Math]::Round($tplBytes / 1MB, 2)
if ($tplMB -gt 3) { $errors += "模板总尺寸 ${tplMB}MB 超过上限 3MB" }

Write-Host "模板完整性检查：$($allDirs.Count) 个模板目录，总尺寸 ${tplMB}MB"
if ($errors.Count -gt 0) {
    Write-Host 'FAIL：'
    $errors | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host 'PASS：全部模板通过完整性检查。'
exit 0