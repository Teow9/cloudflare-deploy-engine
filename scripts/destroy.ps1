# ============================================================
# destroy.ps1 —— 一键销毁（二次确认，DryRun 支持）
# 用法：
#   destroy.ps1 -ConfigPath <p> -Project my-site -DryRun
#   destroy.ps1 -ConfigPath <p> -Project my-site (-Force 跳过交互确认)
# ============================================================

param(
    [string]$ConfigPath = '',
    [string]$Project = '',
    [switch]$Force,
    [switch]$DryRun
)

. (Join-Path $PSScriptRoot 'utils.ps1')
. (Join-Path $PSScriptRoot 'config-manager.ps1')
. (Join-Path $PSScriptRoot 'plugin-manager.ps1')

try {
    if (-not $ConfigPath) { $ConfigPath = (Join-Path (Get-DataDir) 'config.enc.json') }
    Lock-Deploy
    $logStamp = New-Stamp
    $logFile = Join-Path (Join-Path (Get-DataDir) 'logs') ("destroy-$logStamp.log")
    Set-ActiveLogFile -Path $logFile
    try {
        $cfg = Get-AppConfig -Path $ConfigPath
        if (-not $Project) { $Project = $cfg.settings.pagesProject }
        if (-not $Project) { throw '未指定 -Project，且配置中没有记录项目名' }

        if (-not $Force -and -not $DryRun) {
            $ans = Read-Host "确认删除 Pages 项目 '$Project' ？输入 yes 继续"
            if ($ans -ne 'yes') { Write-Result @{ action = 'cancelled'; project = $Project }; exit 0 }
        }

        $result = Invoke-Plugin -Axis 'targets' -Id 'pages' -PluginArgs @{
            ConfigPath = $ConfigPath
            Project    = $Project
            DryRun     = [bool]$DryRun
            Action     = 'delete'
        }

        if (-not $DryRun) {
            # 项目已删除，清除记忆的项目名，避免后续误用
            $cfg.settings.pagesProject = ''
            Save-AppConfig -Path $ConfigPath -Config $cfg
        }
        Write-Result $result
    } finally {
        Unlock-Deploy
    }
} catch {
    Write-LogLine -Level ERROR -Message $_.Exception.Message
    Write-Result @{ error = $_.Exception.Message }
    exit 1
}