# deploy-core 集成冒烟（真实入口、DryRun 全链路，无网络）
# 覆盖回归：dot-source 参数污染（template-manager 顶层 param 覆写 $TemplateId）
#          与 JSON→hashtable 转换（PSCustomObject 不能直传 [hashtable] 参数）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')

function Invoke-DeployCli {
    param([string[]]$ExtraArgs)
    $cfgPath = Join-Path $env:TEMP ("deploycfg-" + [guid]::NewGuid() + '.enc.json')
    Get-AppConfig -Path $cfgPath -Create | Out-Null
    $args = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $script:Root 'scripts\deploy-core.ps1'),
        '-ConfigPath', $cfgPath) + $ExtraArgs
    $out = & powershell.exe @args 2>&1
    $resultLine = $out | Where-Object { $_ -match '^RESULT\|' } | Select-Object -First 1
    Remove-Item -LiteralPath $cfgPath -Force -ErrorAction SilentlyContinue
    if (-not $resultLine) { throw ("deploy-core 未输出 RESULT：{0}" -f ($out -join ' | ')) }
    return ($resultLine -replace '^RESULT\|', '' | ConvertFrom-Json)
}

Describe 'deploy-core DryRun 全链路' {
    It '模板部署 DryRun 返回项目与 URL（无网络、无副作用）' {
        # 注：PS 5.1 嵌套进程传参会把含双引号的 JSON 拆散，这里走默认参数路径；
        #     参数覆盖合并逻辑由 template-manager 单测覆盖
        $r = Invoke-DeployCli -ExtraArgs @('-TemplateId', 'plain', '-DryRun')
        $r.error | Should Be $null
        $r.dryRun | Should Be $true
        $r.project | Should Be 'plain'
        $r.url | Should Be 'https://plain.pages.dev'
        $r.meta.template | Should Be 'plain'
    }
    It '未指定来源时报可读错误' {
        $r = Invoke-DeployCli -ExtraArgs @('-DryRun')
        $r.error | Should Match 'TemplateId'
    }
    It 'ParamsB64 通道解码（UI 安全通道回归，含中文）' {
        $json = '{"site_title":"我的站"}'
        $b64 = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
        $r = Invoke-DeployCli -ExtraArgs @('-TemplateId', 'plain', '-ParamsB64', $b64, '-DryRun')
        $r.error | Should Be $null
        $r.meta.parameters.site_title | Should Be '我的站'
    }
    It '-ListHistory 返回历史数组（蓝图 §4.2 数据层）' {
        $r = Invoke-DeployCli -ExtraArgs @('-ListHistory')
        $r.error | Should Be $null
        $null -ne $r.history | Should Be $true
    }
    It 'DryRun 不写部署历史（无副作用）' {
        $before = @(Read-DeployHistory).Count
        $r = Invoke-DeployCli -ExtraArgs @('-TemplateId', 'plain', '-DryRun')
        $r.error | Should Be $null
        $after = @(Read-DeployHistory).Count
        $after | Should Be $before
    }
    It '-FromHistory 重放历史部署（DryRun，临时数据目录）' {
        $old = $env:CDE_DATA_DIR
        $tmpData = Join-Path $env:TEMP ("cde-fromhist-" + [guid]::NewGuid())
        $env:CDE_DATA_DIR = $tmpData
        try {
            $null = Add-DeployHistory -Project 'hist-proj' -Template 'plain' -Parameters @{ site_title = '重放测试' } -Url 'https://hist-proj.pages.dev'
            $r = Invoke-DeployCli -ExtraArgs @('-FromHistory', '0', '-DryRun')
            $r.error | Should Be $null
            $r.project | Should Be 'hist-proj'
            $r.meta.template | Should Be 'plain'
            $r.meta.parameters.site_title | Should Be '重放测试'
        } finally {
            if ($null -eq $old) { Remove-Item Env:CDE_DATA_DIR -ErrorAction SilentlyContinue } else { $env:CDE_DATA_DIR = $old }
            Remove-Item -LiteralPath $tmpData -Force -Recurse -ErrorAction SilentlyContinue
        }
    }
}