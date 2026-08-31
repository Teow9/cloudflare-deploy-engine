# ============================================================
# plugin-manager.ps1 —— 四轴插件注册与统一分发（ADR-007）
# 轴：sources / templates / ai / targets，注册表：{根}/plugins.json
# handler 契约：scripts/plugins/<轴>/<id>.ps1 定义
#   函数 Invoke-<前缀><PascalId>，仅接受 -PluginArgs（hashtable）
#   前缀映射：sources→Source, templates→Template, ai→Ai, targets→Target
# templates 轴无 handler 文件，由 template-manager 承担（invoke = 取元数据）
# 注意：① 本文件是可点源库脚本，禁止顶层 param（防止污染调用方作用域）
#       ② 参数名用 PluginArgs 而非 Args（后者与自动变量 $args 冲突，PS 5.1 无法绑定）
# ============================================================

. (Join-Path $PSScriptRoot 'utils.ps1')

$script:PluginRegistryCache = $null

function Get-PluginRegistryPath {
    return (Join-Path (Get-EngineRoot) 'plugins.json')
}

function Get-PluginRegistry {
    # 读取并校验四轴注册表（带缓存，-Refresh 可刷新）
    param([switch]$Refresh)
    if ($script:PluginRegistryCache -and -not $Refresh) { return $script:PluginRegistryCache }
    $path = Get-PluginRegistryPath
    if (-not (Test-Path -LiteralPath $path)) { throw "插件注册表不存在：$path" }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($axis in @('sources', 'templates', 'ai', 'targets')) {
        if ($null -eq $raw.$axis) { throw "plugins.json 缺少轴定义：$axis" }
    }
    $script:PluginRegistryCache = $raw
    return $raw
}

function Get-PluginList {
    # 枚举四轴全部插件（含禁用项），供 UI/Get-PluginList 命令返回
    $reg = Get-PluginRegistry
    $list = @()
    foreach ($axis in @('sources', 'templates', 'ai', 'targets')) {
        foreach ($entry in $reg.$axis) {
            $list += [PSCustomObject]@{
                axis    = $axis.TrimEnd('s')      # sources→source → 语义名
                axisKey = $axis
                id      = $entry.id
                enabled = [bool]$entry.enabled
                handler = if ($entry.handler) { $entry.handler } else { '' }
                path    = if ($entry.path) { $entry.path } else { '' }
            }
        }
    }
    return $list
}

function Get-PluginEntry {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sources', 'templates', 'ai', 'targets')][string]$Axis,
        [Parameter(Mandatory = $true)][string]$Id
    )
    $reg = Get-PluginRegistry
    $entry = @($reg.$Axis | Where-Object { $_.id -eq $Id })
    if ($entry.Count -eq 0) { throw "插件未注册：$Axis/$Id（检查 plugins.json）" }
    return $entry[0]
}

function ConvertTo-PascalId {
    # openai-compatible → OpenaiCompatible
    param([Parameter(Mandatory = $true)][string]$Id)
    return (($Id -split '-' | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } }) -join '')
}

function Invoke-Plugin {
    # 统一分发：invoke <axis>.<id> with -PluginArgs hashtable
    # templates 轴 → 返回模板元数据（template-manager）
    param(
        [Parameter(Mandatory = $true)][ValidateSet('sources', 'templates', 'ai', 'targets')][string]$Axis,
        [Parameter(Mandatory = $true)][string]$Id,
        [hashtable]$PluginArgs = @{}
    )
    $entry = Get-PluginEntry -Axis $Axis -Id $Id
    if (-not $entry.enabled) { throw "插件未启用：$Axis/$Id（修改 plugins.json 开启）" }

    if ($Axis -eq 'templates') {
        . (Join-Path $PSScriptRoot 'template-manager.ps1')
        return (Get-TemplateMeta -TemplateId $Id)
    }

    if (-not $entry.handler) { throw "插件缺少 handler：$Axis/$Id" }
    $handlerPath = Join-Path (Get-EngineRoot) $entry.handler
    if (-not (Test-Path -LiteralPath $handlerPath)) { throw "插件 handler 不存在：$handlerPath" }
    . $handlerPath

    $prefix = @{ sources = 'Source'; templates = 'Template'; ai = 'Ai'; targets = 'Target' }[$Axis]
    $fnName = "Invoke-$prefix$(ConvertTo-PascalId $Id)"
    if (-not (Get-Command $fnName -ErrorAction SilentlyContinue)) {
        throw "插件 handler 未导出约定函数 $fnName（见 docs/插件开发指南.md）"
    }
    return (& $fnName -PluginArgs $PluginArgs)
}

# ---------------- 独立运行入口（手动解析参数） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $axis = ''; $id = ''; $argsJson = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            '-Axis'     { $axis = $args[++$i] }
            '-Id'       { $id = $args[++$i] }
            '-ArgsJson' { $argsJson = $args[++$i] }
            default     { Write-LogLine -Level WARN -Message "忽略未知参数：$($args[$i])" }
        }
    }
    try {
        if (-not $axis) {
            Write-Result @{ plugins = @(Get-PluginList) }
        } else {
            $argsHash = @{}
            if ($argsJson) {
                $parsed = $argsJson | ConvertFrom-Json -ErrorAction Stop
                foreach ($p in $parsed.PSObject.Properties) { $argsHash[$p.Name] = $p.Value }
            }
            $result = Invoke-Plugin -Axis $axis -Id $id -PluginArgs $argsHash
            Write-Result @{ axis = $axis; id = $id; result = $result }
        }
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}