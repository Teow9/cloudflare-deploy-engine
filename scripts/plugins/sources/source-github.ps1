# ============================================================
# sources/github 插件 —— GitHub 仓库作为代码来源（零依赖：codeload + tar）
# 契约：Invoke-SourceGithub -PluginArgs @{ Url = 'owner/repo 或完整 URL'; Ref = 'main' }
# 返回：@{ root = <解压根>; source = 'github'; owner; repo; ref }
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')

function Resolve-GithubRef {
    param([string]$Owner, [string]$Repo, [string]$Ref)
    $url = "https://codeload.github.com/$Owner/$Repo/zip/refs/heads/$Ref"
    return $url
}

function Find-ArchiveRoot {
    # tar 解压后若只有单个顶层目录，返回该目录；否则返回解压根
    param([Parameter(Mandatory = $true)][string]$ExtractDir)
    $top = @(Get-ChildItem -LiteralPath $ExtractDir -Directory -ErrorAction SilentlyContinue)
    if ($top.Count -eq 1) { return $top[0].FullName }
    return $ExtractDir
}

function Invoke-SourceGithub {
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('Url')) { throw 'source-github: 缺少 Url' }
    $ref = if ($PluginArgs.ContainsKey('Ref')) { $PluginArgs['Ref'] } else { 'main' }

    $raw = $PluginArgs['Url'].Trim()
    $raw = $raw -replace '\.git$', ''
    $raw = $raw -replace '/$', ''
    $m = [regex]::Match($raw, '^(?:https://github\.com/)?([^/]+)/([^/]+)$')
    if (-not $m.Success) { throw "无法解析 GitHub 仓库地址：$($PluginArgs['Url'])" }
    $owner = $m.Groups[1].Value
    $repo = $m.Groups[2].Value

    $stamp = New-Stamp
    $cache = Join-Path (Get-CacheDir) "github-$owner-$repo-$ref-$stamp"
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $zip = Join-Path $cache 'source.zip'

    Write-LogLine -Level INFO -Message "下载 GitHub 仓库 $owner/$repo@$ref ..."
    & curl.exe --noproxy "*" -L --fail -sS -o $zip (Resolve-GithubRef -Owner $owner -Repo $repo -Ref $ref) 2>$null
    if ($LASTEXITCODE -ne 0) { throw "GitHub 下载失败：$owner/$repo@$ref（检查网络或分支名）" }

    $extract = Join-Path $cache 'src'
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    & tar.exe -xf $zip -C $extract 2>$null
    if ($LASTEXITCODE -ne 0) { throw "解压失败：$zip" }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $root = Find-ArchiveRoot -ExtractDir $extract
    Write-LogLine -Level INFO -Message "代码来源：GitHub $owner/$repo@$ref → $root"
    return @{ root = $root; source = 'github'; owner = $owner; repo = $repo; ref = $ref }
}

if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-SourceGithub -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}