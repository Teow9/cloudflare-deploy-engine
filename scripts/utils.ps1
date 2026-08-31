# ============================================================
# utils.ps1 —— 引擎公共工具库（无副作用，可被任意脚本点源加载）
# 依赖：Windows PowerShell 5.1（powershell.exe），.NET Framework
# ============================================================

# 加载 DPAPI 所在程序集（幂等）
Add-Type -AssemblyName System.Security -ErrorAction Stop

function Get-EngineRoot {
    # 引擎根 = scripts 的上一级
    if ($PSScriptRoot) { return (Split-Path -Parent $PSScriptRoot) }
    throw 'Get-EngineRoot: $PSScriptRoot 为空（请勿直贴执行）'
}

function Get-DataDir {
    # 单测/调试钩子：CDE_DATA_DIR 环境变量重定向数据目录（同 CDE_API_BASE 先例）
    if ($env:CDE_DATA_DIR) {
        $dir = $env:CDE_DATA_DIR
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        return $dir
    }
    $dir = Join-Path (Get-EngineRoot) 'data'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Get-CacheDir {
    $dir = Join-Path (Get-DataDir) 'cache'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    return $dir
}

function Clear-StaleCache {
    # 缓存清理：删除 N 天前的展开产物与 wrangler 日志（默认 1 天，防 data/ 堆积）
    param([int]$Days = 1)
    $cache = Get-CacheDir
    $cutoff = (Get-Date).AddDays(-$Days)
    @(Get-ChildItem -LiteralPath $cache -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }) |
        Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
    @(Get-ChildItem -LiteralPath $cache -File -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt $cutoff }) |
        Remove-Item -Force -ErrorAction SilentlyContinue
}

function New-Stamp {
    # 部署/缓存用时间戳（yyyyMMdd-HHmmss）
    return (Get-Date -Format 'yyyyMMdd-HHmmss')
}

function Write-Utf8File {
    # 统一 UTF-8 无 BOM 写入，避免 JSON/BOM 污染
    param([Parameter(Mandatory = $true)][string]$Path, [Parameter(Mandatory = $true)][string]$Text)
    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Text, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Utf8File {
    param([Parameter(Mandatory = $true)][string]$Path)
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

function Invoke-Curl {
    # 统一 curl 调用：强制 --noproxy "*"；输出拼接为单行字符串
    # 用法：Invoke-Curl -s -H "Authorization: Bearer xxx" 'https://...'
    param([Parameter(ValueFromRemainingArguments = $true)][object[]]$CurlArgs)
    $output = & curl.exe --noproxy "*" @CurlArgs 2>$null
    return ($output -join "`n")
}

# ---------------- 日志与结果协议 ----------------
# 协议：stdout 只输出两种行
#   LOG|timestamp|LEVEL|message      —— UI 实时滚动
#   RESULT|<json>                    —— 命令最终结果

function Write-LogLine {
    param([ValidateSet('INFO','WARN','ERROR','DEBUG')][string]$Level = 'INFO', [Parameter(Mandatory = $true)][string]$Message)
    $line = ('LOG|{0}|{1}|{2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message)
    [Console]::Out.WriteLine($line)
    # 日志落盘（蓝图 §4.2 data/logs/）：Set-ActiveLogFile 激活后追加写
    if ($script:ActiveLogFile) {
        try { [System.IO.File]::AppendAllText($script:ActiveLogFile, ($line + "`r`n"), [System.Text.Encoding]::UTF8) } catch { }
    }
}

function Set-ActiveLogFile {
    # 激活日志文件（部署/销毁入口调用；-Path '' 关闭）
    param([string]$Path = '')
    $script:ActiveLogFile = $Path
    if ($Path) {
        $dir = Split-Path -Parent $Path
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        try { [System.IO.File]::AppendAllText($Path, "==== CDE 会话 $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') ====`r`n", [System.Text.Encoding]::UTF8) } catch { }
    }
}

function Write-Result {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 12 -Compress
    [Console]::Out.WriteLine(('RESULT|{0}' -f $json))
}

# ---------------- 脱敏 ----------------
function ConvertTo-RedactedText {
    param([Parameter(Mandatory = $true)][string]$Text)
    $t = $Text
    $t = [regex]::Replace($t, '("apiToken"\s*:\s*")[^"]*(")', '${1}***${2}')
    $t = [regex]::Replace($t, '("apiKey"\s*:\s*")[^"]*(")', '${1}***${2}')
    $t = [regex]::Replace($t, '("password"\s*:\s*")[^"]*(")', '${1}***${2}')
    $t = [regex]::Replace($t, '(Authorization:\s*Bearer\s+)[A-Za-z0-9_\-\.]+', '${1}***')
    return $t
}

# ---------------- DPAPI 本地加密（机器+用户绑定，见 ADR-003） ----------------
function Protect-Secret {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlainText)
    if ([string]::IsNullOrEmpty($PlainText)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainText)
    $enc = [System.Security.Cryptography.ProtectedData]::Protect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [Convert]::ToBase64String($enc)
}

function Unprotect-Secret {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Encoded)
    if ([string]::IsNullOrEmpty($Encoded)) { return '' }
    $bytes = [Convert]::FromBase64String($Encoded)
    $dec = [System.Security.Cryptography.ProtectedData]::Unprotect(
        $bytes, $null, [System.Security.Cryptography.DataProtectionScope]::CurrentUser)
    return [System.Text.Encoding]::UTF8.GetString($dec)
}

# ---------------- 口令保护（换机迁移，PBKDF2 + AES-256-CBC + HMAC-SHA256） ----------------
# 载荷格式：base64(salt):base64(iv):base64(cipher):base64(tag)（encrypt-then-MAC）

function Protect-WithPassphrase {
    param(
        [Parameter(Mandatory = $true)][string]$Passphrase,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$PlainText
    )
    if ($Passphrase.Length -lt 8) { throw '口令长度不得少于 8 个字符' }
    $text = [System.Text.Encoding]::UTF8.GetBytes($PlainText)

    $salt = New-Object byte[] 16
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($salt)

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $salt, 100000)
    $key = $derive.GetBytes(32)
    $derive.Dispose()

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.KeySize = 256
    $aes.GenerateIV()
    $iv = $aes.IV

    $enc = $aes.CreateEncryptor($key, $iv)
    $ms = New-Object System.IO.MemoryStream
    $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $enc, [System.Security.Cryptography.CryptoStreamMode]::Write)
    $cs.Write($text, 0, $text.Length)
    $cs.FlushFinalBlock()
    $cipher = $ms.ToArray()
    $cs.Dispose(); $ms.Dispose(); $aes.Dispose(); $enc.Dispose()

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $tag = $hmac.ComputeHash($cipher)
    $hmac.Dispose(); $key = $null

    return ([Convert]::ToBase64String($salt) + ':' + [Convert]::ToBase64String($iv) + ':' +
            [Convert]::ToBase64String($cipher) + ':' + [Convert]::ToBase64String($tag))
}

function Unprotect-WithPassphrase {
    param(
        [Parameter(Mandatory = $true)][string]$Passphrase,
        [Parameter(Mandatory = $true)][string]$Payload
    )
    $parts = $Payload -split ':', 4
    if ($parts.Count -ne 4) { throw '口令载荷格式错误' }
    $salt = [Convert]::FromBase64String($parts[0])
    $iv = [Convert]::FromBase64String($parts[1])
    $cipher = [Convert]::FromBase64String($parts[2])
    $tag = [Convert]::FromBase64String($parts[3])

    $derive = New-Object System.Security.Cryptography.Rfc2898DeriveBytes($Passphrase, $salt, 100000)
    $key = $derive.GetBytes(32)
    $derive.Dispose()

    $hmac = [System.Security.Cryptography.HMACSHA256]::new($key)
    $computed = $hmac.ComputeHash($cipher)
    $hmac.Dispose()
    if ($computed.Length -ne $tag.Length) { throw '口令错误或载荷被篡改' }
    for ($i = 0; $i -lt $tag.Length; $i++) {
        if ($computed[$i] -ne $tag[$i]) { throw '口令错误或载荷被篡改' }
    }

    $aes = [System.Security.Cryptography.Aes]::Create()
    $aes.Mode = [System.Security.Cryptography.CipherMode]::CBC
    $aes.Padding = [System.Security.Cryptography.PaddingMode]::PKCS7
    $aes.KeySize = 256
    $dec = $aes.CreateDecryptor($key, $iv)
    $ms = [System.IO.MemoryStream]::new($cipher)
    $cs = New-Object System.Security.Cryptography.CryptoStream($ms, $dec, [System.Security.Cryptography.CryptoStreamMode]::Read)
    $sr = New-Object System.IO.StreamReader($cs, [System.Text.Encoding]::UTF8)
    $plain = $sr.ReadToEnd()
    $sr.Dispose(); $cs.Dispose(); $ms.Dispose(); $aes.Dispose(); $dec.Dispose(); $key = $null
    return $plain
}

function New-TempJsonFile {
    # JSON 过 native 参数边界会被 PS 5.1 剥掉双引号（CRT 引号解析），
    # 统一写临时文件，用 --data-binary @file / manifest=@file 传递。
    # 调用方负责 finally 删除。
    param([Parameter(Mandatory = $true)][string]$Json)
    $file = Join-Path $env:TEMP ("cde-body-" + [guid]::NewGuid().ToString('N') + '.json')
    Write-Utf8File -Path $file -Text $Json
    return $file
}

# ---------------- 部署历史（蓝图 §4.2 deploy-history.json，明文） ----------------
function Get-HistoryPath {
    return (Join-Path (Get-DataDir) 'deploy-history.json')
}

function Read-DeployHistory {
    # 读取部署历史（-Limit 0 = 全部；最新在后）
    # 注意：PS 5.1 中 @(管道 | ConvertFrom-Json) 会把输出包成单元素（解析器怪癖），
    #       必须先赋值再 @() 包装
    param([int]$Limit = 50)
    $p = Get-HistoryPath
    if (-not (Test-Path -LiteralPath $p)) { return @() }
    try {
        $parsed = Get-Content -LiteralPath $p -Raw -Encoding UTF8 | ConvertFrom-Json
        $arr = @($parsed)
    } catch {
        Write-LogLine -Level WARN -Message "部署历史文件损坏，按空处理：$p"
        return @()
    }
    if ($Limit -gt 0 -and $arr.Count -gt $Limit) { $arr = @($arr | Select-Object -Last $Limit) }
    return $arr
}

function Add-DeployHistory {
    # 追加一条部署记录（上限 50 条，超出丢最旧）
    param(
        [Parameter(Mandatory = $true)][string]$Project,
        [string]$Source = '',
        [hashtable]$SourceArgs = @{},
        [string]$Template = '',
        [hashtable]$Parameters = @{},
        [string]$Url = '',
        [ValidateSet('ok', 'failed', 'cancelled')][string]$Status = 'ok',
        [bool]$ServingOk = $false,
        [int]$Attempts = 0,
        [string]$Backend = '',
        [string]$DeploymentId = '',
        [string]$LogFile = ''
    )
    $MaxKeep = 50
    $rec = [PSCustomObject]@{
        timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        project      = $Project
        source       = $Source
        sourceArgs   = $SourceArgs
        template     = $Template
        parameters   = $Parameters
        url          = $Url
        status       = $Status
        servingOk    = [bool]$ServingOk
        attempts     = $Attempts
        backend      = $Backend
        deploymentId = $DeploymentId
        logFile      = $LogFile
    }
    $all = @(Read-DeployHistory -Limit 0)
    $all += $rec
    if ($all.Count -gt $MaxKeep) { $all = @($all | Select-Object -Skip ($all.Count - $MaxKeep)) }
    Write-Utf8File -Path (Get-HistoryPath) -Text ($all | ConvertTo-Json -Depth 8)
    return $rec
}

# ---------------- 部署运行锁（计划 §2.2：并发互斥 + 死锁自愈） ----------------
function Lock-Deploy {
    # 加锁：data/.deploy.lock（JSON {pid,started}）；锁内 PID 已退出 → 视为过期自动接管
    $lockPath = Join-Path (Get-DataDir) '.deploy.lock'
    if (Test-Path -LiteralPath $lockPath) {
        $info = $null
        try { $info = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { }
        $pidAlive = $false
        if ($info -and $info.pid) {
            $proc = Get-Process -Id ([int]$info.pid) -ErrorAction SilentlyContinue
            $pidAlive = ($null -ne $proc)
        }
        if ($pidAlive) {
            throw ("已有部署任务进行中（PID {0}，起始 {1}）。请等待完成，或手动结束对应进程后重试。" -f $info.pid, $info.started)
        }
        Write-LogLine -Level WARN -Message ("发现过期部署锁（PID {0} 已不存在），自动接管" -f $(if ($info.pid) { $info.pid } else { '未知' }))
    }
    $body = @{ pid = $PID; started = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') } | ConvertTo-Json -Compress
    Write-Utf8File -Path $lockPath -Text $body
}

function Unlock-Deploy {
    # 释放锁（仅当锁属于当前进程；异常时强制清理）
    $lockPath = Join-Path (Get-DataDir) '.deploy.lock'
    if (-not (Test-Path -LiteralPath $lockPath)) { return }
    try {
        $info = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($info.pid -eq $PID) { Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue }
    } catch {
        Remove-Item -LiteralPath $lockPath -Force -ErrorAction SilentlyContinue
        Write-LogLine -Level WARN -Message '部署锁内容异常，已强制清理'
    }
}

# ---------------- 随机工具 ----------------
function New-RandomHex {
    param([int]$Length = 32)
    $bytes = New-Object byte[] ($Length / 2)
    [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLower()
}

function ConvertTo-ProjectSlug {
    # 把任意字符串转成 Pages 项目名（小写字母数字连字符）
    param([string]$Name)
    $slug = ($Name -replace '[^A-Za-z0-9\-]', '-') -replace '\-+', '-'
    $slug = $slug.Trim('-').ToLower()
    if (-not $slug) { throw "无法从 '$Name' 生成合法项目名" }
    return $slug
}