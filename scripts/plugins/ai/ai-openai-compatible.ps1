# ============================================================
# ai/openai-compatible 插件 —— OpenAI 兼容协议 AI 后端（ADR-004）
# 契约：Invoke-AiOpenaiCompatible -PluginArgs @{
#   BaseUrl='https://api.openai.com/v1'; ApiKey='...'; Model='...';
#   SystemPrompt='...'; UserPrompt='...' }
# 返回：@{ content = <模型回复文本>; model = ... }
# ============================================================

. (Join-Path $PSScriptRoot '..\..\utils.ps1')

function Invoke-AiOpenaiCompatible {
    param([hashtable]$PluginArgs = @{})
    foreach ($k in @('BaseUrl', 'ApiKey', 'Model', 'SystemPrompt', 'UserPrompt')) {
        if (-not $PluginArgs.ContainsKey($k)) { throw "ai-openai-compatible: 缺少 $k" }
    }
    $baseUrl = $PluginArgs['BaseUrl'].TrimEnd('/')
    $body = @{
        model    = $PluginArgs['Model']
        messages = @(
            @{ role = 'system'; content = $PluginArgs['SystemPrompt'] },
            @{ role = 'user'; content = $PluginArgs['UserPrompt'] }
        )
        temperature = 0.2
    } | ConvertTo-Json -Depth 8 -Compress

    Write-LogLine -Level INFO -Message "调用 AI：$baseUrl/chat/completions（model=$($PluginArgs['Model'])）"
    $tmpBody = New-TempJsonFile -Json $body
    try {
        $resp = Invoke-Curl -s -X POST -H "Authorization: Bearer $($PluginArgs['ApiKey'])" -H 'Content-Type: application/json' --data-binary ('@' + $tmpBody) "$baseUrl/chat/completions"
    } finally {
        Remove-Item -LiteralPath $tmpBody -Force -ErrorAction SilentlyContinue
    }
    $obj = $resp | ConvertFrom-Json
    if (-not $obj.choices -or $obj.choices.Count -eq 0) {
        $err = if ($obj.error) { $obj.error.message } else { '空响应' }
        throw "AI 调用失败：$err"
    }
    return @{ content = [string]$obj.choices[0].message.content; model = [string]$obj.model }
}

if ($MyInvocation.InvocationName -ne '.') {
    $a = @{}
    if ($args.Count -ge 1 -and $args[0]) {
        $o = $args[0] | ConvertFrom-Json -ErrorAction SilentlyContinue
        if ($o) { foreach ($p in $o.PSObject.Properties) { $a[$p.Name] = $p.Value } }
    }
    try {
        Write-Result (Invoke-AiOpenaiCompatible -PluginArgs $a)
    } catch {
        Write-LogLine -Level ERROR -Message $_.Exception.Message
        Write-Result @{ error = $_.Exception.Message }
        exit 1
    }
}