# ============================================================
# template-manager.ps1 —— 模板轴实现（plugins.json templates 段）
#   Get-TemplateList          —— 已启用模板清单
#   Get-TemplateMeta <id>     —— 读取 template.json（合并默认值）
#   Expand-TemplateParams     —— 占位符 {{param}} 替换到输出目录
# 注意：可点源库脚本，禁止顶层 param（防止污染调用方作用域）；
#       独立运行参数（模板 id）在入口用 $args 读取。
# ============================================================

. (Join-Path $PSScriptRoot 'utils.ps1')

function Get-TemplateRegistry {
    $reg = Get-Content -LiteralPath (Join-Path (Get-EngineRoot) 'plugins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    return $reg.templates
}

function Get-TemplateList {
    # 返回已启用模板 {id, name, path, enabled}
    $list = @()
    foreach ($entry in @(Get-TemplateRegistry)) {
        if (-not $entry.enabled) { continue }
        $metaPath = Join-Path (Get-EngineRoot) (Join-Path $entry.path 'template.json')
        $name = $entry.id
        if (Test-Path -LiteralPath $metaPath) {
            $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $name = $meta.name
        }
        $list += [PSCustomObject]@{ id = $entry.id; name = $name; path = $entry.path; enabled = $true }
    }
    return $list
}

function Get-TemplatePath {
    param([Parameter(Mandatory = $true)][string]$TemplateId)
    $entry = @(Get-TemplateRegistry | Where-Object { $_.id -eq $TemplateId })
    if ($entry.Count -eq 0) { throw "模板未注册：$TemplateId" }
    if (-not $entry[0].enabled) { throw "模板未启用：$TemplateId" }
    return (Join-Path (Get-EngineRoot) $entry[0].path)
}

function Get-TemplateMeta {
    param([Parameter(Mandatory = $true)][string]$TemplateId)
    $dir = Get-TemplatePath -TemplateId $TemplateId
    $metaPath = Join-Path $dir 'template.json'
    if (-not (Test-Path -LiteralPath $metaPath)) { throw "模板缺少 template.json：$dir" }
    $meta = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if (-not $meta.parameters) { $meta | Add-Member -NotePropertyName parameters -NotePropertyValue @() -Force }
    if (-not $meta.cloudflare) { $meta | Add-Member -NotePropertyName cloudflare -NotePropertyValue ([PSCustomObject]@{ kv = $false; env = @{} }) -Force }
    if (-not $meta.ai) { $meta | Add-Member -NotePropertyName ai -NotePropertyValue ([PSCustomObject]@{ keywords = @() }) -Force }
    return $meta
}

function Get-TemplateParametersWithDefaults {
    param([Parameter(Mandatory = $true)]$Meta, [hashtable]$Overrides = @{})
    $merged = @{}
    foreach ($p in $Meta.parameters) {
        $merged[$p.name] = $p.default
    }
    foreach ($k in $Overrides.Keys) { $merged[$k] = $Overrides[$k] }
    return $merged
}

function Expand-TemplateParams {
    # 拷贝模板产物目录 → OutDir，并对文本文件做 {{key}} 占位符替换
    param(
        [Parameter(Mandatory = $true)][string]$TemplateDir,
        [hashtable]$Params = @{},
        [Parameter(Mandatory = $true)][string]$OutDir
    )
    if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Path $OutDir -Force | Out-Null }
    $textExts = @('.html', '.htm', '.css', '.js', '.mjs', '.json', '.md', '.txt', '.xml', '.svg', '.yaml', '.yml', '.toml')
    $files = @(Get-ChildItem -LiteralPath $TemplateDir -Recurse -File | Where-Object { $_.Name -ne 'template.json' })
    foreach ($f in $files) {
        $rel = ConvertTo-RelativePath -Base $TemplateDir -FullName $f.FullName
        $dest = Join-Path $OutDir $rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        $ext = $f.Extension.ToLower()
        if ($textExts -contains $ext) {
            $content = Read-Utf8File -Path $f.FullName
            foreach ($k in $Params.Keys) {
                $content = $content.Replace("{{$k}}", [string]$Params[$k])
            }
            Write-Utf8File -Path $dest -Text $content
        } else {
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        }
    }
    return $OutDir
}

# ---------------- 独立运行入口（手动解析参数） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $tplId = ''
    if ($args.Count -ge 1) { $tplId = $args[0] }
    try {
        if (-not $tplId) {
            Write-Result @{ templates = @(Get-TemplateList) }
        } else {
            Write-Result (Get-TemplateMeta -TemplateId $tplId)
        }
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}