# engine-state.tests.ps1 —— 部署历史 / 运行锁 / 日志落盘（蓝图 §4.2 + 计划 §2.2）
# 数据目录经 CDE_DATA_DIR 重定向到临时目录，不污染仓库 data/。
$script:Root = Split-Path -Parent $PSScriptRoot
. (Join-Path $script:Root 'scripts\utils.ps1')
. (Join-Path $script:Root 'scripts\config-manager.ps1')

# 每个 shell 进程一次 dot-source 后环境变量固定——Pester 同进程多次 Describe 共享；
# 在文件顶层直接设置（本文件专用进程），finally 不需要恢复（子进程隔离）。
$script:OldDataDir = $env:CDE_DATA_DIR
$script:TestData = Join-Path $env:TEMP ("cde-test-data-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $script:TestData -Force | Out-Null
$env:CDE_DATA_DIR = $script:TestData

Describe '部署历史（deploy-history.json，明文，上限 50）' {
    It 'Add 后可读回，字段齐全' {
        $rec = Add-DeployHistory -Project 'p1' -Template 'plain' -Parameters @{ site_title = '测试' } `
            -Url 'https://p1.pages.dev' -Status 'ok' -ServingOk $true -Attempts 1 -Backend 'native' `
            -DeploymentId 'abc123' -LogFile 'deploy-1.log'
        $rec.project | Should Be 'p1'
        $all = @(Read-DeployHistory)
        $all.Count | Should Be 1
        $all[0].url | Should Be 'https://p1.pages.dev'
        $all[0].parameters.site_title | Should Be '测试'
    }
    It '超过 50 条时丢弃最旧' {
        for ($i = 0; $i -lt 55; $i++) { Add-DeployHistory -Project ("p$i") | Out-Null }
        $all = @(Read-DeployHistory)
        $all.Count | Should Be 50
        $all[0].project | Should Be 'p5'     # 共 56 条（含首测 p1），留 50 丢 6：p1,p0..p4 → 起点 p5
        $all[-1].project | Should Be 'p54'
        # 清理本文件产生的历史，避免影响其它测试
        Remove-Item -LiteralPath (Get-HistoryPath) -Force -ErrorAction SilentlyContinue
    }
}

Describe '部署运行锁（并发互斥 + 死锁自愈）' {
    It '互斥：持锁期间再锁被拒' {
        Lock-Deploy
        { Lock-Deploy } | Should Throw
        Unlock-Deploy
    }
    It '解锁后可以再加锁' {
        Lock-Deploy | Out-Null
        Unlock-Deploy
        { Lock-Deploy } | Should Not Throw
        Unlock-Deploy
    }
    It '死锁自愈：锁内 PID 不存在时自动接管' {
        $lockPath = Join-Path $script:TestData '.deploy.lock'
        Write-Utf8File -Path $lockPath -Text (@{ pid = 99999999; started = '2026-01-01 00:00:00' } | ConvertTo-Json -Compress)
        { Lock-Deploy } | Should Not Throw
        $info = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $info.pid | Should Be $PID
        Unlock-Deploy
    }
    It '释放后锁文件消失' {
        Lock-Deploy | Out-Null
        Unlock-Deploy
        (Test-Path -LiteralPath (Join-Path $script:TestData '.deploy.lock')) | Should Be $false
    }
}

Describe '日志落盘（data/logs/）' {
    It '激活日志文件后 Write-LogLine 追加写入' {
        $logPath = Join-Path $script:TestData 'logs\deploy-test.log'
        Set-ActiveLogFile -Path $logPath
        Write-LogLine -Level INFO -Message '日志落盘测试'
        Write-LogLine -Level WARN -Message '警告也落盘'
        Set-ActiveLogFile -Path ''
        (Test-Path -LiteralPath $logPath) | Should Be $true
        $content = Get-Content -LiteralPath $logPath -Raw -Encoding UTF8
        $content | Should Match '日志落盘测试'
        $content | Should Match '警告也落盘'
    }
    It '未激活日志文件时不落盘也不报错' {
        Set-ActiveLogFile -Path ''
        $pre = @(Get-ChildItem -LiteralPath (Join-Path $script:TestData 'logs') -File -ErrorAction SilentlyContinue).Count
        Write-LogLine -Level INFO -Message '不落盘的行为'
        $post = @(Get-ChildItem -LiteralPath (Join-Path $script:TestData 'logs') -File -ErrorAction SilentlyContinue).Count
        $post | Should Be $pre
    }
}

# 恢复环境变量，避免泄漏给同进程的后续测试文件；并清理本文件产生的临时数据目录
if ($null -eq $script:OldDataDir) { Remove-Item Env:CDE_DATA_DIR -ErrorAction SilentlyContinue }
else { $env:CDE_DATA_DIR = $script:OldDataDir }
Remove-Item -LiteralPath $script:TestData -Force -Recurse -ErrorAction SilentlyContinue