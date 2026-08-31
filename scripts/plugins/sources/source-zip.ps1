# ============================================================
# sources/zip 插件 —— 本地压缩包作为代码来源（tar 解压 zip，零依赖）
# 契约：Invoke-SourceZip -PluginArgs @{ Path = 'C:\x\site.zip' }
# 返回：@{ root = <解压根>; source = 'zip'; archive = <路径> }
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')

function Find-ArchiveRoot {
    param([Parameter(Mandatory = $true)][string]$ExtractDir)
    $top = @(Get-ChildItem -LiteralPath $ExtractDir -Directory -ErrorAction SilentlyContinue)
    if ($top.Count -eq 1) { return $top[0].FullName }
    return $ExtractDir
}

function Invoke-SourceZip {
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('Path')) { throw 'source-zip: 缺少 Path' }
    $zip = $PluginArgs['Path']
    if (-not (Test-Path -LiteralPath $zip -PathType Leaf)) { throw "压缩包不存在：$zip" }
    $ext = [System.IO.Path]::GetExtension($zip).ToLower()
    if ($ext -notin @('.zip', '.tar', '.tar.gz', '.tgz')) { throw "不支持的压缩包格式：$ext" }

    $stamp = New-Stamp
    $name = [System.IO.Path]::GetFileNameWithoutExtension($zip)
    $cache = Join-Path (Get-CacheDir) "zip-$name-$stamp"
    New-Item -ItemType Directory -Path $cache -Force | Out-Null

    & tar.exe -xf $zip -C $cache 2>$null
    if ($LASTEXITCODE -ne 0) { throw "解压失败：$zip" }

    $root = Find-ArchiveRoot -ExtractDir $cache
    Write-LogLine -Level INFO -Message "代码来源：压缩包 $zip → $root"
    return @{ root = $root; source = 'zip'; archive = $zip }
}

if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-SourceZip -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}