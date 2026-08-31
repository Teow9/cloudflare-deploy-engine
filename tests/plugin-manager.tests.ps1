# plugin-manager 单元测试（四轴注册与分发，ADR-007）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\plugin-manager.ps1')

Describe '插件注册表' {
    It 'plugins.json 四轴齐全' {
        $reg = Get-PluginRegistry -Refresh
        $reg.sources.Count | Should Be 4
        $reg.templates.Count | Should Be 5
        $reg.ai.Count | Should Be 1
        $reg.targets.Count | Should Be 1
    }
    It 'Get-PluginList 枚举四轴（理念指标：sources×4/templates×5/ai×1/targets×1）' {
        $list = @(Get-PluginList)
        $list.Count | Should Be 11
        @($list | Where-Object { $_.axisKey -eq 'sources' }).Count | Should Be 4
        @($list | Where-Object { $_.axisKey -eq 'templates' }).Count | Should Be 5
        @($list | Where-Object { $_.axisKey -eq 'ai' }).Count | Should Be 1
        @($list | Where-Object { $_.axisKey -eq 'targets' }).Count | Should Be 1
    }
    It '未注册插件抛错' {
        { Get-PluginEntry -Axis sources -Id no-such-plugin } | Should Throw
    }
}

Describe '插件分发' {
    It 'source-local 返回真实根目录' {
        $tmp = Join-Path $env:TEMP ("src-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        $r = Invoke-Plugin -Axis sources -Id local -PluginArgs @{ Path = $tmp }
        $r.root | Should Be (Resolve-Path -LiteralPath $tmp).Path
        Remove-Item -LiteralPath $tmp -Force
    }
    It 'source-local 对不存在路径抛错' {
        { Invoke-Plugin -Axis sources -Id local -PluginArgs @{ Path = 'Z:\no-such-dir-xyz' } } | Should Throw
    }
    It 'templates 轴 invoke 返回模板元数据' {
        $meta = Invoke-Plugin -Axis templates -Id plain -PluginArgs @{}
        $meta.id | Should Be 'plain'
        $meta.parameters.Count | Should Be 2
    }
    It 'source-gitlab archive URL 解析（D4，多段路径）' {
        . (Join-Path $script:Root 'scripts\plugins\sources\source-gitlab.ps1')
        Resolve-GitlabArchiveUrl -Raw 'group/sub-group/project' -Ref 'main' |
            Should Be 'https://gitlab.com/group/sub-group/project/-/archive/main/project-main.zip'
        Resolve-GitlabArchiveUrl -Raw 'https://gitlab.com/a/b' -Ref 'v1.0' |
            Should Be 'https://gitlab.com/a/b/-/archive/v1.0/b-v1.0.zip'
    }
    It '禁用插件不可调用（临时禁用后恢复，不依赖注册表默认状态）' {
        $regPath = Join-Path $script:Root 'plugins.json'
        $orig = Get-Content -LiteralPath $regPath -Raw -Encoding UTF8
        try {
            $reg = $orig | ConvertFrom-Json
            $reg.sources | Where-Object { $_.id -eq 'zip' } | ForEach-Object { $_.enabled = $false }
            [System.IO.File]::WriteAllText($regPath, ($reg | ConvertTo-Json -Depth 6),
                (New-Object System.Text.UTF8Encoding($false)))
            $script:PluginRegistryCache = $null
            { Invoke-Plugin -Axis sources -Id zip -PluginArgs @{ Path = 'x.zip' } } | Should Throw
        } finally {
            [System.IO.File]::WriteAllText($regPath, $orig, (New-Object System.Text.UTF8Encoding($false)))
            $script:PluginRegistryCache = $null
        }
    }
}