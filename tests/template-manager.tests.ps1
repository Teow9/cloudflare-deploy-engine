# template-manager 单元测试（模板轴）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\template-manager.ps1')

Describe '模板清单与元数据' {
    It 'Get-TemplateList 返回五个已启用模板' {
        $list = @(Get-TemplateList)
        $list.Count | Should Be 5
        $ids = @($list | ForEach-Object { $_.id })
        ($ids -contains 'plain') | Should Be $true
        ($ids -contains 'astro-site') | Should Be $true
        ($ids -contains 'react-vite') | Should Be $true
        ($ids -contains 'docs-site') | Should Be $true
        ($ids -contains 'nav-site') | Should Be $true
    }
    It 'react-vite 模板含 enum 参数（A4）' {
        $meta = Get-TemplateMeta -TemplateId react-vite
        $theme = @($meta.parameters | Where-Object { $_.name -eq 'theme' })[0]
        $theme.type | Should Be 'enum'
        $theme.enum | Should Be @('light', 'dark')
    }
    It 'Get-TemplateMeta 解析参数与 ai 关键词' {
        $meta = Get-TemplateMeta -TemplateId plain
        $meta.cloudflare.kv | Should Be $false
        $meta.parameters[0].name | Should Be 'site_title'
        $meta.ai.keywords.Count | Should BeGreaterThan 0
    }
    It '未知模板抛错' {
        { Get-TemplateMeta -TemplateId nope } | Should Throw
    }
}

Describe '参数展开（占位符）' {
    It '默认值与覆盖值合并，{{site_title}} 被替换' {
        $meta = Get-TemplateMeta -TemplateId plain
        $merged = Get-TemplateParametersWithDefaults -Meta $meta -Overrides @{ site_title = '我的博客' }
        $merged.ContainsKey('site_tagline') | Should Be $true
        $merged['site_title'] | Should Be '我的博客'

        $out = Join-Path $env:TEMP ("tpl-" + [guid]::NewGuid())
        Expand-TemplateParams -TemplateDir (Get-TemplatePath -TemplateId plain) -Params $merged -OutDir $out | Out-Null
        $html = Read-Utf8File -Path (Join-Path $out 'index.html')
        $html | Should Match '我的博客'
        $html | Should Not Match '\{\{site_title\}\}'
        Remove-Item -LiteralPath $out -Recurse -Force
    }
    It '二进制文件不参与替换（拷贝即可）' {
        $meta = Get-TemplateMeta -TemplateId plain
        $merged = Get-TemplateParametersWithDefaults -Meta $meta
        $src = Join-Path $env:TEMP ("bin-" + [guid]::NewGuid())
        New-Item -ItemType Directory -Path $src -Force | Out-Null
        [System.IO.File]::WriteAllBytes((Join-Path $src 'a.bin'), [byte[]](0x00, 0x01, 0x02))
        $out = Join-Path $env:TEMP ("tpl-o-" + [guid]::NewGuid())
        Expand-TemplateParams -TemplateDir $src -Params $merged -OutDir $out | Out-Null
        (Test-Path -LiteralPath (Join-Path $out 'a.bin')) | Should Be $true
        Remove-Item -LiteralPath $src, $out -Recurse -Force
    }
}