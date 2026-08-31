# ============================================================
# sources/local 插件 —— 本地文件夹作为代码来源
# 契约：Invoke-SourceLocal -PluginArgs @{ Path = '...' }
# 返回：@{ root = <绝对路径>; source = 'local' }
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')

function Invoke-SourceLocal {
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('Path')) { throw 'source-local: 缺少 Path' }
    $path = $PluginArgs['Path']
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { throw "本地文件夹不存在：$path" }
    $root = (Resolve-Path -LiteralPath $path).Path
    Write-LogLine -Level INFO -Message "代码来源：本地文件夹 $root"
    return @{ root = $root; source = 'local' }
}

if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-SourceLocal -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}