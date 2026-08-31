# ============================================================
# ai-bridge.ps1 —— AI 方案生成（蓝图 §6 工作流，ADR-004）
# 流程：用户需求 → 组装提示（注入模板元数据）→ ai.openai-compatible
#       → JSON 解析（容错）→ 回填建议 RESULT；永不自动部署。
# 用法：ai-bridge.ps1 -ConfigPath <p> -Request '我想做一个个人博客'
# ============================================================

param(
    [string]$ConfigPath = '',
    [Parameter(Mandatory = $true)][string]$Request
)

. (Join-Path $PSScriptRoot 'utils.ps1')
. (Join-Path $PSScriptRoot 'config-manager.ps1')
. (Join-Path $PSScriptRoot 'template-manager.ps1')
. (Join-Path $PSScriptRoot 'plugin-manager.ps1')

function New-SystemPrompt {
    param($TemplateMetas)
    return @"
你是一个 Cloudflare Pages 部署专家。用户用自然语言描述想要部署的网站，你需要从可用模板中选择最合适的，并给出完整配置参数。

## 可用模板
$(($TemplateMetas | ConvertTo-Json -Depth 6))

## 输出格式（必须为合法 JSON）
{"template":"模板ID","projectName":"合法项目名（小写字母数字连字符）","parameters":{"参数名":"值"},"explanation":"1-2 句推荐理由"}

## 规则
1. 优先匹配需求关键词（模板的 ai.keywords）
2. projectName 必须合法，长度 2-32
3. 未指定的参数使用模板 default
4. 只输出 JSON，不要输出其他文字
"@
}

function Invoke-AiSuggest {
    $cfg = Get-AppConfig -Path $ConfigPath
    if (-not $cfg.ai.baseUrl -or -not $cfg.ai.apiKey -or -not $cfg.ai.model) {
        throw '未配置 AI（baseUrl/apiKey/model），请先填写 AI 设置'
    }

    $metas = @()
    foreach ($t in @(Get-TemplateList)) {
        $meta = Get-TemplateMeta -TemplateId $t.id
        $metas += [PSCustomObject]@{
            id = $meta.id; name = $meta.name; description = $meta.description
            parameters = $meta.parameters; keywords = $meta.ai.keywords
        }
    }
    if ($metas.Count -eq 0) { throw '没有可用模板（plugins.json templates 为空）' }

    $system = New-SystemPrompt -TemplateMetas $metas
    $raw = Invoke-Plugin -Axis 'ai' -Id 'openai-compatible' -PluginArgs @{
        BaseUrl      = $cfg.ai.baseUrl
        ApiKey       = $cfg.ai.apiKey
        Model        = $cfg.ai.model
        SystemPrompt = $system
        UserPrompt   = $Request
    }

    # ---- 容错解析：剥离代码围栏后转 JSON ----
    $content = $raw.content.Trim()
    $content = [regex]::Replace($content, '^```[a-zA-Z]*\s*', '')
    $content = [regex]::Replace($content, '```\s*$', '')
    $suggestion = $content | ConvertFrom-Json -ErrorAction Stop

    foreach ($k in @('template', 'projectName', 'parameters', 'explanation')) {
        if ($null -eq $suggestion.$k) { throw "AI 返回缺少字段：$k" }
    }
    $known = @(Get-TemplateList | ForEach-Object { $_.id })
    if ($known -notcontains $suggestion.template) { throw "AI 返回了未注册模板：$($suggestion.template)" }

    return @{
        template    = $suggestion.template
        projectName = $suggestion.projectName
        parameters  = $suggestion.parameters
        explanation = $suggestion.explanation
        model       = $raw.model
    }
}

# ---------------- 入口 ----------------
try {
    if (-not $ConfigPath) { $ConfigPath = (Join-Path (Get-DataDir) 'config.enc.json') }
    Write-Result (Invoke-AiSuggest)
} catch {
    Write-LogLine -Level ERROR -Message $_.Exception.Message
    Write-Result @{ error = $_.Exception.Message }
    exit 1
}