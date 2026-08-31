# config-manager 单元测试（Pester 3.x）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')

Describe '配置读写（DPAPI 落盘）' {
    It '创建→设置→读取往返' {
        $tmp = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        $cfg = Get-AppConfig -Path $tmp -Create
        $cfg | Should Not Be $null
        (Test-Path -LiteralPath $tmp) | Should Be $true

        Set-SecretField -Path $tmp -Field accountId -Value 'acc-1'
        Set-SecretField -Path $tmp -Field apiToken -Value 'cfut_secret'

        $re = Get-AppConfig -Path $tmp
        $re.secrets.accountId | Should Be 'acc-1'
        $re.secrets.apiToken | Should Be 'cfut_secret'
        # 落盘内容必须是密文（不含明文 Token）
        $raw = Get-Content -LiteralPath $tmp -Raw -Encoding UTF8
        $raw | Should Not Match 'cfut_secret'
        Remove-Item -LiteralPath $tmp -Force
    }
    It '缺少配置且无 -Create 时抛错' {
        $tmp = Join-Path $env:TEMP ("missing-" + [guid]::NewGuid() + '.enc.json')
        { Get-AppConfig -Path $tmp } | Should Throw
    }
}

Describe '导出/导入（换机迁移，ADR-003）' {
    It '导出文件不含明文，导入后可解密' {
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        $outPath = Join-Path $env:TEMP ("exp-" + [guid]::NewGuid() + '.json')
        $g = Get-AppConfig -Path $cfgPath -Create
        $g.ai.baseUrl = 'https://api.openai.com/v1'; $g.ai.model = 'gpt-4o-mini'; $g.ai.apiKey = 'sk-demo'
        Save-AppConfig -Path $cfgPath -Config $g

        Export-ConfigFile -Path $cfgPath -Passphrase 'migrate-pass-1' -OutFile $outPath
        $exported = Get-Content -LiteralPath $outPath -Raw -Encoding UTF8
        $exported | Should Not Match 'sk-demo'          # 导出文件不含明文
        $exported | Should Match 'cde-export-v1'

        # 模拟目标机：新空配置文件导入
        $newPath = Join-Path $env:TEMP ("cfg-new-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $newPath -Create | Out-Null
        Import-ConfigFile -Path $newPath -Passphrase 'migrate-pass-1' -InFile $outPath
        $imported = Get-AppConfig -Path $newPath
        $imported.secrets.apiToken | Should Be $g.secrets.apiToken
        $imported.ai.apiKey | Should Be 'sk-demo'
        Remove-Item -LiteralPath $cfgPath, $outPath, $newPath -Force
    }
    It '错误口令导入被拒绝' {
        $cfgPath = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        $outPath = Join-Path $env:TEMP ("exp-" + [guid]::NewGuid() + '.json')
        Get-AppConfig -Path $cfgPath -Create | Out-Null
        Export-ConfigFile -Path $cfgPath -Passphrase 'migrate-pass-1' -OutFile $outPath
        $newPath = Join-Path $env:TEMP ("cfg-new-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $newPath -Create | Out-Null
        { Import-ConfigFile -Path $newPath -Passphrase 'wrong-pass' -InFile $outPath } | Should Throw
        Remove-Item -LiteralPath $cfgPath, $outPath, $newPath -Force
    }
}

Describe '清除配置' {
    It 'Clear 删除文件' {
        $tmp = Join-Path $env:TEMP ("cfg-" + [guid]::NewGuid() + '.enc.json')
        Get-AppConfig -Path $tmp -Create | Out-Null
        Clear-ConfigFile -Path $tmp
        (Test-Path -LiteralPath $tmp) | Should Be $false
    }
}