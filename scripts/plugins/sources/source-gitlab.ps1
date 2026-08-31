# ============================================================
# sources/gitlab 插件 —— GitLab 仓库作为代码来源（零依赖：archive zip + tar）
# 契约：Invoke-SourceGitlab -PluginArgs @{ Url = 'group/project 或完整 URL'; Ref = 'main' }
# 返回：@{ root = <解压根>; source = 'gitlab'; path; ref }
# 下载端点：https://gitlab.com/<path>/-/archive/<ref>/<name>-<ref>.zip
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')

function Resolve-GitlabArchiveUrl {
    # 可测函数：解析仓库路径与 ref → GitLab archive zip URL
    param([Parameter(Mandatory = $true)][string]$Raw, [string]$Ref = 'main')
    $t = $Raw.Trim()
    $t = $t -replace '/$', ''
    $m = [regex]::Match($t, '^(?:https://gitlab\.com/)?([^/]+/.+)$')
    if (-not $m.Success) { throw "无法解析 GitLab 仓库地址：$Raw（需要 group/project 或完整 URL）" }
    $path = $m.Groups[1].Value
    $name = Split-Path -Leaf $path
    return "https://gitlab.com/$path/-/archive/$Ref/$name-$Ref.zip"
}

function Invoke-SourceGitlab {
    param([hashtable]$PluginArgs = @{})
    if (-not $PluginArgs.ContainsKey('Url')) { throw 'source-gitlab: 缺少 Url' }
    $ref = if ($PluginArgs.ContainsKey('Ref')) { $PluginArgs['Ref'] } else { 'main' }
    $url = Resolve-GitlabArchiveUrl -Raw $PluginArgs['Url'] -Ref $ref

    $stamp = New-Stamp
    $cache = Join-Path (Get-CacheDir) "gitlab-$stamp"
    New-Item -ItemType Directory -Path $cache -Force | Out-Null
    $zip = Join-Path $cache 'source.zip'

    Write-LogLine -Level INFO -Message "下载 GitLab 仓库归档（ref=$ref）…"
    & curl.exe --noproxy "*" -L --fail -sS -o $zip $url 2>$null
    if ($LASTEXITCODE -ne 0) { throw "GitLab 下载失败：$url（检查网络、仓库路径或分支名）" }

    $extract = Join-Path $cache 'src'
    New-Item -ItemType Directory -Path $extract -Force | Out-Null
    & tar.exe -xf $zip -C $extract 2>$null
    if ($LASTEXITCODE -ne 0) { throw "解压失败：$zip" }
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue

    $top = @(Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue)
    $root = if ($top.Count -eq 1) { $top[0].FullName } else { $extract }
    Write-LogLine -Level INFO -Message "代码来源：GitLab（ref=$ref）→ $root"
    return @{ root = $root; source = 'gitlab'; ref = $ref }
}

if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-SourceGitlab -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}