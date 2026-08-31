# utils.ps1 单元测试（Pester 3.x / Windows PowerShell 5.1）
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')

Describe 'DPAPI 加解密' {
    It 'Protect/Unprotect 往返一致' {
        $enc = Protect-Secret 'my-secret-token'
        $enc | Should Not Be ''
        Unprotect-Secret $enc | Should Be 'my-secret-token'
    }
    It '空值保持为空' {
        Protect-Secret '' | Should Be ''
        Unprotect-Secret '' | Should Be ''
    }
}

Describe '口令保护（换机迁移，ADR-003）' {
    It '口令加密/解密往返一致（含中文）' {
        $payload = Protect-WithPassphrase -Passphrase 'test-pass-123' -PlainText '{"apiToken":"cfut_abc123"}'
        Unprotect-WithPassphrase -Passphrase 'test-pass-123' -Payload $payload | Should Be '{"apiToken":"cfut_abc123"}'
    }
    It '错误口令被拒绝（HMAC 校验）' {
        $payload = Protect-WithPassphrase -Passphrase 'test-pass-123' -PlainText 'secret'
        { Unprotect-WithPassphrase -Passphrase 'wrong-pass-999' -Payload $payload } | Should Throw
    }
    It '短口令被拒绝' {
        { Protect-WithPassphrase -Passphrase 'short' -PlainText 'x' } | Should Throw
    }
}

Describe '脱敏' {
    It 'Token/密码字段被打码' {
        $t = ConvertTo-RedactedText '{"apiToken":"cfut_abc","apiKey":"sk-123","password":"p1"} Authorization: Bearer cfut_abc'
        $t | Should Not Match 'cfut_abc'
        $t | Should Not Match 'sk-123'
        $t | Should Not Match 'Bearer\s+(?!\*\*\*)'
    }
}

Describe 'UTF-8 无 BOM 写入' {
    It '写入文件无 BOM 且内容一致' {
        $tmp = Join-Path $env:TEMP ("utils-test-" + [guid]::NewGuid() + '.json')
        Write-Utf8File -Path $tmp -Text '{"a":"中"}'
        $bytes = [System.IO.File]::ReadAllBytes($tmp)
        $bytes[0] | Should Not Be 0xEF
        Read-Utf8File -Path $tmp | Should Be '{"a":"中"}'
        Remove-Item -LiteralPath $tmp -Force
    }
}

Describe '项目名规范化' {
    It '非法字符转连字符并小写' {
        ConvertTo-ProjectSlug 'My Site_中文!' | Should Be 'my-site'
    }
    It '空结果抛错' {
        { ConvertTo-ProjectSlug '!!!' } | Should Throw
    }
}

Describe '相对路径（8.3 短名免疫，GH runner CI 回归）' {
    It '常规路径前缀匹配' {
        ConvertTo-RelativePath -Base 'C:\site\src' -FullName 'C:\site\src\index.html' | Should Be 'index.html'
        ConvertTo-RelativePath -Base 'C:\site\src' -FullName 'C:\site\src\assets\app.js' | Should Be 'assets/app.js'
    }
    It '短名 Base + 长名 FullName（RUNNER~1 vs runneradmin）' {
        ConvertTo-RelativePath -Base 'C:\Users\RUNNER~1\AppData\Local\Temp\site-x' `
            -FullName 'C:\Users\runneradmin\AppData\Local\Temp\site-x\index.html' | Should Be 'index.html'
        ConvertTo-RelativePath -Base 'C:\Users\RUNNER~1\AppData\Local\Temp\site-x' `
            -FullName 'C:\Users\runneradmin\AppData\Local\Temp\site-x\assets\app.js' | Should Be 'assets/app.js'
    }
}