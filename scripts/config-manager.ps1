# ============================================================
# config-manager.ps1 —— data/config.enc.json 读写与迁移（ADR-003）
# 结构：secrets（DPAPI 加密） / settings（明文） / ai（apiKey 加密）
# 注意：本文件是可点源的库脚本，禁止顶层 param（会污染调用方作用域），
#       独立运行参数在入口用 $args 手动解析。
# 用法（独立运行）：
#   config-manager.ps1 -ConfigPath <p> -Verb get
#   config-manager.ps1 -ConfigPath <p> -Verb set -Field apiToken -Value <v>
#   config-manager.ps1 -ConfigPath <p> -Verb export -Passphrase <pw> -OutFile <f>
#   config-manager.ps1 -ConfigPath <p> -Verb import -Passphrase <pw> -InFile <f>
#   config-manager.ps1 -ConfigPath <p> -Verb clear
# ============================================================

. (Join-Path $PSScriptRoot 'utils.ps1')

function Get-DefaultConfigPath {
    return (Join-Path (Get-DataDir) 'config.enc.json')
}

function New-DefaultConfig {
    return [PSCustomObject]@{
        version  = 1
        settings = [PSCustomObject]@{ pagesProject = ''; lastTemplate = '' }
        secrets  = [PSCustomObject]@{ accountId = ''; apiToken = ''; email = '' }
        ai       = [PSCustomObject]@{ baseUrl = ''; model = ''; apiKey = '' }
    }
}

function Read-ConfigFileRaw {
    # 读原始 JSON（不解密）
    param([Parameter(Mandatory = $true)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "配置文件不存在：$Path" }
    return (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Get-AppConfig {
    # 装载配置；secrets/ai.apiKey 自动解密为明文（仅进程内）
    param([string]$Path = '', [switch]$Create)
    if (-not $Path) { $Path = Get-DefaultConfigPath }
    if (-not (Test-Path -LiteralPath $Path)) {
        if (-not $Create) { throw "配置文件不存在：$Path（先运行 config-manager.ps1 -Verb get 创建）" }
        Save-AppConfig -Path $Path -Config (New-DefaultConfig)
    }
    $raw = Read-ConfigFileRaw -Path $Path
    if ($raw.version -ne 1) { throw "不支持的配置版本：$($raw.version)" }
    return [PSCustomObject]@{
        Path     = $Path
        settings = $raw.settings
        secrets  = [PSCustomObject]@{
            accountId = Unprotect-Secret $raw.secrets.accountId
            apiToken  = Unprotect-Secret $raw.secrets.apiToken
            email     = Unprotect-Secret $raw.secrets.email
        }
        ai       = [PSCustomObject]@{
            baseUrl = $raw.ai.baseUrl
            model   = $raw.ai.model
            apiKey  = Unprotect-Secret $raw.ai.apiKey
        }
    }
}

function Save-AppConfig {
    # 落盘：secrets/ai.apiKey 先加密
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)]$Config
    )
    $body = [PSCustomObject]@{
        version  = 1
        settings = $Config.settings
        secrets  = [PSCustomObject]@{
            accountId = Protect-Secret $Config.secrets.accountId
            apiToken  = Protect-Secret $Config.secrets.apiToken
            email     = Protect-Secret $Config.secrets.email
        }
        ai       = [PSCustomObject]@{
            baseUrl = $Config.ai.baseUrl
            model   = $Config.ai.model
            apiKey  = Protect-Secret $Config.ai.apiKey
        }
    }
    Write-Utf8File -Path $Path -Text ($body | ConvertTo-Json -Depth 10)
}

function Set-SecretField {
    # 便捷更新：-Field accountId|apiToken|email|aiApiKey|aiBaseUrl|aiModel
    param(
        [string]$Path = '',
        [Parameter(Mandatory = $true)][ValidateSet('accountId', 'apiToken', 'email', 'aiApiKey', 'aiBaseUrl', 'aiModel')][string]$Field,
        [string]$Value = ''
    )
    $cfg = Get-AppConfig -Path $Path -Create
    switch ($Field) {
        'accountId' { $cfg.secrets.accountId = $Value }
        'apiToken'  { $cfg.secrets.apiToken = $Value }
        'email'     { $cfg.secrets.email = $Value }
        'aiApiKey'  { $cfg.ai.apiKey = $Value }
        'aiBaseUrl' { $cfg.ai.baseUrl = $Value }
        'aiModel'   { $cfg.ai.model = $Value }
    }
    Save-AppConfig -Path $cfg.Path -Config $cfg
    return $cfg
}

function Export-ConfigFile {
    # 换机迁移导出：口令加密（ADR-003），明文仅存在于导出 JSON 的内存副本
    param(
        [string]$Path = '',
        [Parameter(Mandatory = $true)][string]$Passphrase,
        [Parameter(Mandatory = $true)][string]$OutFile
    )
    $cfg = Get-AppConfig -Path $Path
    $plain = [PSCustomObject]@{
        format   = 'cde-export-v1'
        settings = $cfg.settings
        secrets  = $cfg.secrets
        ai       = $cfg.ai
    } | ConvertTo-Json -Depth 10 -Compress
    $payload = Protect-WithPassphrase -Passphrase $Passphrase -PlainText $plain
    Write-Utf8File -Path $OutFile -Text ('{"format":"cde-export-v1","payload":"' + $payload + '"}')
    Write-LogLine -Level INFO -Message "已导出到 $OutFile（口令加密，目标机重新导入）"
}

function Import-ConfigFile {
    # 换机迁移导入：口令解密 → 目标机重新 DPAPI 加密落盘
    param(
        [string]$Path = '',
        [Parameter(Mandatory = $true)][string]$Passphrase,
        [Parameter(Mandatory = $true)][string]$InFile
    )
    $wrap = Get-Content -LiteralPath $InFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($wrap.format -ne 'cde-export-v1') { throw "不是有效的导出文件：$InFile" }
    $plain = Unprotect-WithPassphrase -Passphrase $Passphrase -Payload $wrap.payload
    $data = $plain | ConvertFrom-Json
    if ($data.format -ne 'cde-export-v1') { throw '导出文件内容格式错误' }
    $new = New-DefaultConfig
    $new.settings = $data.settings
    $new.secrets = $data.secrets
    $new.ai = $data.ai
    if (-not $Path) { $Path = Get-DefaultConfigPath }
    Save-AppConfig -Path $Path -Config $new
    Write-LogLine -Level INFO -Message "已导入并在本机重新加密：$Path"
    return $new
}

function Clear-ConfigFile {
    param([string]$Path = '')
    if (-not $Path) { $Path = Get-DefaultConfigPath }
    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Force
        Write-LogLine -Level INFO -Message "已清除配置：$Path"
    } else {
        Write-LogLine -Level WARN -Message "配置不存在，无需清除：$Path"
    }
}

# ---------------- 独立运行入口（手动解析参数，避免顶层 param） ----------------
if ($MyInvocation.InvocationName -ne '.') {
    $cfgPath = ''; $verb = 'get'; $field = ''; $value = ''
    $pass = ''; $out = ''; $in = ''
    for ($i = 0; $i -lt $args.Count; $i++) {
        switch ($args[$i]) {
            '-ConfigPath' { $cfgPath = $args[++$i] }
            '-Verb'       { $verb = $args[++$i] }
            '-Field'      { $field = $args[++$i] }
            '-Value'      { $value = $args[++$i] }
            '-ValueB64'   {
                # UI 通道：值经 Base64（UTF-8），免疫命令行引号/编码问题
                try { $value = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($args[++$i])) }
                catch { throw 'ValueB64 不是合法 Base64' }
            }
            '-Passphrase' { $pass = $args[++$i] }
            '-OutFile'    { $out = $args[++$i] }
            '-InFile'     { $in = $args[++$i] }
            default       { Write-LogLine -Level WARN -Message "忽略未知参数：$($args[$i])" }
        }
    }
    try {
        if (-not $cfgPath) { $cfgPath = Get-DefaultConfigPath }
        switch ($verb) {
            'get'    { Write-Result (Get-AppConfig -Path $cfgPath -Create) }
            'set'    {
                if (-not $field) { throw 'set 需要 -Field（accountId|apiToken|email|aiApiKey|aiBaseUrl|aiModel）' }
                Set-SecretField -Path $cfgPath -Field $field -Value $value | Out-Null
                Write-Result @{ action = 'set'; field = $field; saved = $true }
            }
            'export' {
                if (-not $pass) { throw 'export 需要 -Passphrase' }
                if (-not $out) { throw 'export 需要 -OutFile' }
                Export-ConfigFile -Path $cfgPath -Passphrase $pass -OutFile $out
                Write-Result @{ action = 'export'; out = $out }
            }
            'import' {
                if (-not $pass) { throw 'import 需要 -Passphrase' }
                if (-not $in) { throw 'import 需要 -InFile' }
                Import-ConfigFile -Path $cfgPath -Passphrase $pass -InFile $in | Out-Null
                Write-Result @{ action = 'import'; path = $cfgPath }
            }
            'clear'  { Clear-ConfigFile -Path $cfgPath; Write-Result @{ action = 'clear' } }
            default  { throw "未知 Verb：$verb" }
        }
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}