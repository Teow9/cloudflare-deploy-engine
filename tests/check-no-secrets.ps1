# ============================================================
# check-no-secrets.ps1 —— 修正版无凭据扫描（评估结论：不再豁免 config/deploy）
# 只忽略运行时目录与开发产物；文本文件全量扫描。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests\check-no-secrets.ps1
# ============================================================

$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot

$patterns = @(
    'cfut_[A-Za-z0-9_\-]{20,}',
    'sk-[A-Za-z0-9]{20,}',
    '[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}',
    'API[_-]?KEY\s*[=:]\s*["'']?[A-Za-z0-9]{16,}',
    '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
)

# 测试 fixture 中的假 UUID（utils 无；保留兼容）
$allowedFakeUuids = @('aa55ec46-5085-4e05-8ae2-df2641f57fe2')

# 只忽略运行时/构建产物目录；config/deploy 不再豁免
$excludeDirs = @('data', '.git', '.neu', 'node_modules', 'bin', 'Temporary file')
$textExtensions = @('.md', '.txt', '.ps1', '.psd1', '.json', '.yml', '.yaml', '.html', '.css', '.js', '.xml', '.example')

$files = Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
    Where-Object {
        $rel = $_.FullName.Substring($Root.Length).TrimStart('\', '/')
        $top = ($rel -split '[\\/]')[0]
        $excludeDirs -notcontains $top -and $rel -notmatch 'pnpm-lock|package-lock' -and
        $textExtensions -contains $_.Extension.ToLower()
    }

$found = @()
foreach ($file in $files) {
    $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
    if ($null -eq $content) { continue }
    foreach ($pattern in $patterns) {
        $matches = [regex]::Matches($content, $pattern)
        foreach ($m in $matches) {
            if ($allowedFakeUuids -contains $m.Value) { continue }
            if ($m.Value -match '@(example\.com|example\.org|example\.net)$') { continue }  # 占位示例邮箱
            $found += ("{0}: /{1}/ 命中「{2}」" -f $file.FullName, $pattern, $m.Value)
        }
    }
}

if ($found.Count -gt 0) {
    Write-Host '发现潜在凭据：'
    $found | Sort-Object -Unique | ForEach-Object { Write-Host "  $_" }
    exit 1
}
Write-Host "无凭据扫描通过：$($files.Count) 个文本文件未发现敏感内容。"
exit 0