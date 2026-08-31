# ============================================================
# market.ps1 —— 插件市场（B1，最小闭环：registry 远程清单 + 安装/卸载）
# 协议：
#   registry JSON = { "plugins": [ { "axis","id","name","version",
#                                    "description","url","sha256" } ] }
#   url 支持 http(s)（curl 下载）与本地路径（Copy，测试/离线用）
# 安装落位：
#   templates 轴 → 整个解压根 → templates/<id>/
#   其它轴（sources/ai/targets）→ 包内 <id>.ps1（首个递归匹配）→ scripts/plugins/<轴>/<id>.ps1
#   随后注册 plugins.json（幂等；-Force 覆盖）
# 卸载：注销 + 删文件；内置插件受白名单保护，不可卸载
# 用法：
#   market.ps1 -ConfigPath <p> registry
#   market.ps1 -ConfigPath <p> search <关键词>
#   market.ps1 -ConfigPath <p> install <轴> <id> [-Force]
#   market.ps1 -ConfigPath <p> uninstall <id>
# 数据源：-MarketUrl 参数 > CDE_MARKET_URL 环境变量 > 配置 settings.marketUrl > 内置默认
# ============================================================

. (Join-Path $PSScriptRoot 'utils.ps1')
. (Join-Path $PSScriptRoot 'config-manager.ps1')

$script:MarketDefaultUrl = 'https://raw.githubusercontent.com/cloudflare-deploy-engine/market/main/market.json'

function Get-MarketUrl {
    param([string]$Explicit = '', [string]$ConfigPath = '')
    if ($Explicit) { return $Explicit }
    if ($env:CDE_MARKET_URL) { return $env:CDE_MARKET_URL }
    if ($ConfigPath) {
        try {
            $cfg = Get-AppConfig -Path $ConfigPath
            if ($cfg.settings.marketUrl) { return [string]$cfg.settings.marketUrl }
        } catch { }
    }
    return $script:MarketDefaultUrl
}

function Read-MarketRegistry {
    param([Parameter(Mandatory = $true)][string]$Url)
    $tmp = New-TempJsonFile -Json '{}'
    Remove-Item -LiteralPath $tmp -Force
    try {
        if (Test-Path -LiteralPath $Url) {
            Copy-Item -LiteralPath $Url -Destination $tmp -Force
        } else {
            & curl.exe --noproxy "*" -L --fail -sS --connect-timeout 15 -o $tmp $Url 2>$null
            if ($LASTEXITCODE -ne 0) { throw "市场清单下载失败：$Url（exit=$LASTEXITCODE）" }
        }
        $raw = Read-Utf8File -Path $tmp
        $reg = $raw | ConvertFrom-Json
        if ($null -eq $reg.plugins) { throw '市场清单缺少 plugins 数组' }
        return @{ source = $Url; plugins = @($reg.plugins) }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Write-PluginRegistry {
    # 原子修改 plugins.json（读 → 改 → UTF-8 无 BOM 写回）
    param([scriptblock]$Mutator)
    $path = Join-Path (Get-EngineRoot) 'plugins.json'
    $reg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    & $Mutator $reg
    Write-Utf8File -Path $path -Text ($reg | ConvertTo-Json -Depth 8)
}

function Get-MarketEntry {
    param($Registry, [Parameter(Mandatory = $true)][string]$Axis, [Parameter(Mandatory = $true)][string]$Id)
    $hit = @($Registry.plugins | Where-Object { $_.axis -eq $Axis -and $_.id -eq $Id })
    if ($hit.Count -eq 0) { throw "市场中没有 $Axis/$Id（先 market search 确认）" }
    return $hit[0]
}

function Test-PluginInstalled {
    param([Parameter(Mandatory = $true)][string]$Axis, [Parameter(Mandatory = $true)][string]$Id)
    $reg = Get-Content -LiteralPath (Join-Path (Get-EngineRoot) 'plugins.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $arr = @($reg.$Axis | Where-Object { $_.id -eq $Id })
    return $arr.Count -gt 0
}

function Install-MarketPlugin {
    param(
        [Parameter(Mandatory = $true)][string]$Axis,
        [Parameter(Mandatory = $true)][string]$Id,
        [string]$Url = '',
        [string]$Sha256 = '',
        [switch]$Force
    )
    if ($Axis -notin @('sources', 'templates', 'ai', 'targets')) { throw "未知轴：$Axis" }
    if ((Test-PluginInstalled -Axis $Axis -Id $Id) -and -not $Force) {
        throw "插件已安装：$Axis/$Id（-Force 覆盖）"
    }

    # 1. 下载 + SHA256 校验（不匹配即拒绝并清理）
    $stamp = New-Stamp
    $work = Join-Path (Get-DataDir) "market-$Id-$stamp"
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    $zip = Join-Path $work 'pkg.zip'
    try {
        if (Test-Path -LiteralPath $Url) {
            Copy-Item -LiteralPath $Url -Destination $zip -Force
        } else {
            & curl.exe --noproxy "*" -L --fail -sS --connect-timeout 20 -o $zip $Url 2>$null
            if ($LASTEXITCODE -ne 0) { throw "插件包下载失败：$Url（exit=$LASTEXITCODE）" }
        }
        if ($Sha256) {
            $actual = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
            if ($actual -ne $Sha256.ToLower()) {
                throw "SHA256 校验失败：期望 $Sha256，实际 $actual（已拒绝安装）"
            }
        }
        Write-LogLine -Level INFO -Message "SHA256 校验通过（$($Sha256.Substring(0, [Math]::Min(16, $Sha256.Length)))…）"

        # 2. 解压
        $extract = Join-Path $work 'src'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null
        & tar.exe -xf $zip -C $extract 2>$null
        if ($LASTEXITCODE -ne 0) { throw "解压失败：$zip" }
        $top = @(Get-ChildItem -LiteralPath $extract -Directory -ErrorAction SilentlyContinue)
        $root = if ($top.Count -eq 1) { $top[0].FullName } else { $extract }

        # 3. 落位
        if ($Axis -eq 'templates') {
            if (-not (Test-Path -LiteralPath (Join-Path $root 'template.json'))) { throw '模板包缺少 template.json' }
            $destDir = Join-Path (Get-EngineRoot) "templates\$Id"
            if (Test-Path -LiteralPath $destDir) { Remove-Item -LiteralPath $destDir -Force -Recurse }
            Copy-Item -LiteralPath $root -Destination $destDir -Recurse -Force
            Write-LogLine -Level INFO -Message "模板落位：templates\$Id"
        } else {
            $ps1 = @(Get-ChildItem -LiteralPath $root -Recurse -Filter "$Id.ps1" -File | Select-Object -First 1)
            if ($ps1.Count -eq 0) { throw "插件包内未找到 $Id.ps1（安装契约）" }
            $axisDir = Join-Path (Get-EngineRoot) "scripts\plugins\$Axis"
            if (-not (Test-Path -LiteralPath $axisDir)) { New-Item -ItemType Directory -Path $axisDir -Force | Out-Null }
            Copy-Item -LiteralPath $ps1[0].FullName -Destination (Join-Path $axisDir "$Id.ps1") -Force
            Write-LogLine -Level INFO -Message "handler 落位：scripts\plugins\$Axis\$Id.ps1"
        }

        # 4. 注册 plugins.json（幂等：-Force 时先移除旧的）
        # 注意：PS 变量大小写不敏感，循环变量用 $ax 避免吞掉参数 $Axis
        Write-PluginRegistry -Mutator {
            param($Reg)
            $axisKey = $Axis
            foreach ($ax in @('sources', 'templates', 'ai', 'targets')) {
                if ($ax -eq $Axis) { continue }
                # 从其它轴清除同名条目（防串轴）
                $arr = @($Reg.$ax | Where-Object { $_.id -ne $Id })
                $Reg.$ax = $arr
            }
            $cur = @($Reg.$axisKey | Where-Object { $_.id -ne $Id })
            if ($Axis -eq 'templates') {
                $cur += [PSCustomObject]@{ id = $Id; enabled = $true; path = "templates/$Id" }
            } else {
                $cur += [PSCustomObject]@{ id = $Id; enabled = $true; handler = "scripts/plugins/$Axis/$Id.ps1" }
            }
            $Reg.$axisKey = $cur
        }
        Write-LogLine -Level INFO -Message "已注册 plugins.json：$Axis/$Id"
        return @{ action = 'install'; axis = $Axis; id = $Id }
    } finally {
        Remove-Item -LiteralPath $work -Force -Recurse -ErrorAction SilentlyContinue
    }
}

function Uninstall-MarketPlugin {
    param([Parameter(Mandatory = $true)][string]$Id)
    $builtin = @{
        sources = @('local', 'github', 'gitlab', 'zip')
        templates = @('plain', 'astro-site')
        ai = @('openai-compatible')
        targets = @('pages')
    }
    $path = Join-Path (Get-EngineRoot) 'plugins.json'
    $reg = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $found = $null
    foreach ($axis in @('sources', 'templates', 'ai', 'targets')) {
        $hit = @($reg.$axis | Where-Object { $_.id -eq $Id })
        if ($hit.Count -gt 0) { $found = @{ axis = $axis; entry = $hit[0] }; break }
    }
    if (-not $found) { throw "插件未安装：$Id" }
    if ($found.axis -in $builtin.Keys -and $builtin[$found.axis] -contains $Id) {
        throw "内置插件不可卸载：$Id（$($found.axis) 轴基础能力）"
    }
    # 注销（循环变量用 $ax，与 Install 一致防吞变量）
    Write-PluginRegistry -Mutator {
        param($Reg)
        foreach ($ax in @('sources', 'templates', 'ai', 'targets')) {
            $arr = @($Reg.$ax | Where-Object { $_.id -ne $Id })
            $Reg.$ax = $arr
        }
    }
    # 删文件
    if ($found.axis -eq 'templates') {
        $dir = Join-Path (Get-EngineRoot) "templates\$Id"
        if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Force -Recurse }
    } else {
        $handler = Join-Path (Get-EngineRoot) "scripts\plugins\$($found.axis)\$Id.ps1"
        if (Test-Path -LiteralPath $handler) { Remove-Item -LiteralPath $handler -Force }
    }
    Write-LogLine -Level INFO -Message "已卸载：$Id"
    return @{ action = 'uninstall'; id = $Id }
}

# ---------------- 独立运行入口（手动解析参数） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $verb = 'registry'; $axis = ''; $id = ''; $q = ''; $urlArg = ''
    $force = $false; $cfgPath = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            '-ConfigPath' { $cfgPath = $args[++$i] }
            '-Verb'       { $verb = $args[++$i] }
            '-Axis'       { $axis = $args[++$i] }
            '-Id'         { $id = $args[++$i] }
            '-Query'      { $q = $args[++$i] }
            '-MarketUrl'  { $urlArg = $args[++$i] }
            '-Force'      { $force = $true }
            default       { Write-LogLine -Level WARN -Message "忽略未知参数：$($args[$i])" }
        }
    }
    try {
        if (-not $cfgPath) { $cfgPath = (Join-Path (Get-DataDir) 'config.enc.json') }
        $url = Get-MarketUrl -Explicit $urlArg -ConfigPath $cfgPath
        switch ($verb) {
            'registry' {
                $reg = Read-MarketRegistry -Url $url
                Write-Result @{ source = $reg.source; plugins = $reg.plugins }
            }
            'search' {
                $reg = Read-MarketRegistry -Url $url
                $kw = $q.ToLower()
                $hits = @($reg.plugins | Where-Object {
                    -not $kw -or $_.id.ToLower().Contains($kw) -or $_.name.ToLower().Contains($kw) -or
                    $_.description.ToLower().Contains($kw) -or $_.axis.ToLower().Contains($kw)
                })
                Write-Result @{ source = $reg.source; plugins = $hits }
            }
            'install' {
                if (-not $axis -or -not $id) { throw 'install 需要 -Axis 与 -Id' }
                $reg = Read-MarketRegistry -Url $url
                $entry = Get-MarketEntry -Registry $reg -Axis $axis -Id $id
                $r = Install-MarketPlugin -Axis $axis -Id $id -Url $entry.url -Sha256 $entry.sha256 -Force:$force
                Write-Result $r
            }
            'uninstall' {
                if (-not $id) { throw 'uninstall 需要 -Id' }
                Write-Result (Uninstall-MarketPlugin -Id $id)
            }
            default { throw "未知 Verb：$verb（registry|search|install|uninstall）" }
        }
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}