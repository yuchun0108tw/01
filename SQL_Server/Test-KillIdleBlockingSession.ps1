#requires -Version 5.1
<#
.SYNOPSIS
  對指定的 SQL Server (容器) 部署 KillIdleBlockingSession.sql 並進行自動化驗證。
.EXAMPLE
  .\Test-KillIdleBlockingSession.ps1 -Server localhost,14339 -Password 'EsunAdmin@1313'
#>
param(
    [Parameter(Mandatory)] [string] $Server,
    [Parameter(Mandatory)] [string] $Password,
    [string] $User = 'sa'
)
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function New-Conn($db) {
    $c = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$db;User Id=$User;Password=$Password;TrustServerCertificate=True;Pooling=False;Connect Timeout=10"
    $c.Open(); $c
}
function Run($c, $sql) {
    $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; $cmd.CommandTimeout = 60
    $dt = New-Object System.Data.DataTable
    $dt.Load($cmd.ExecuteReader()); ,$dt
}
function Alive($c) { try { [void](Run $c 'SELECT 1'); $true } catch { $false } }
$script:fail = 0
function Check($name, $cond) {
    if ($cond) { Write-Host "  PASS  $name" -ForegroundColor Green }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:fail++ }
}

# 等待 SQL Server 啟動
for ($i = 0; $i -lt 30; $i++) { try { $m = New-Conn 'master'; break } catch { Start-Sleep 3 } }
if (-not $m) { throw "無法連線 $Server" }
Write-Host ("Server: " + (Run $m "SELECT @@VERSION").Rows[0][0].Split("`n")[0])

# 部署 (以 GO 切批後逐批執行，不依賴 sqlcmd)；連續執行兩次以驗證可重複部署
function Deploy {
    $text = [IO.File]::ReadAllText((Join-Path $here 'KillIdleBlockingSession.sql'))
    $dc = New-Conn 'master'
    try {
        foreach ($batch in [regex]::Split($text, '(?im)^\s*GO\s*$')) {
            if ($batch.Trim()) { [void](Run $dc $batch) }
        }
        $true
    } catch { Write-Host $_.Exception.Message -ForegroundColor Yellow; $false }
    finally { $dc.Dispose() }
}
Check 'Deploy script 執行成功' (Deploy)
Check 'Deploy script 可重複執行' (Deploy)

$job = Run $m @"
SELECT j.enabled, s.freq_type, s.freq_subday_type, s.freq_subday_interval
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
WHERE j.name=N'DBA - Kill Idle Blocking Sessions'
"@
Check 'Job 已建立、啟用、每 20 分鐘' ($job.Rows.Count -eq 1 -and $job.Rows[0].enabled -eq 1 -and $job.Rows[0].freq_subday_type -eq 4 -and $job.Rows[0].freq_subday_interval -eq 20)

# 測試資料
[void](Run $m "IF DB_ID('testdb') IS NOT NULL BEGIN ALTER DATABASE testdb SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE testdb; END; CREATE DATABASE testdb;")
[void](Run $m "TRUNCATE TABLE master.dbo.IdleSessionKillLog")
$setup = New-Conn 'testdb'
[void](Run $setup "CREATE TABLE t1(id INT PRIMARY KEY, v INT); CREATE TABLE t2(id INT PRIMARY KEY, v INT); INSERT t1 VALUES(1,0); INSERT t2 VALUES(1,0);")
$setup.Dispose()

$A = New-Conn 'testdb'   # 閒置 + 阻塞他人 -> 應被 KILL
$B = New-Conn 'testdb'   # 被 A 阻塞
$C = New-Conn 'testdb'   # 閒置 + 持有 Lock 但未阻塞任何人 -> 不應被 KILL
$D = New-Conn 'testdb'   # 閒置、無交易、無阻塞 -> 不應被 KILL
$spidA = (Run $A 'SELECT @@SPID').Rows[0][0]; $spidC = (Run $C 'SELECT @@SPID').Rows[0][0]
[void](Run $A 'BEGIN TRAN; UPDATE t1 SET v=1 WHERE id=1;')
[void](Run $C 'BEGIN TRAN; UPDATE t2 SET v=1 WHERE id=1;')
$cmdB = $B.CreateCommand(); $cmdB.CommandText = 'UPDATE t1 SET v=2 WHERE id=1;'; $cmdB.CommandTimeout = 120
$asyncB = $cmdB.BeginExecuteNonQuery()
Start-Sleep 3
Write-Host "SPID A=$spidA (blocker), C=$spidC (idle non-blocker)"

function KillRun($procArgs) { Start-Sleep -Milliseconds 500; [void](Run $m "EXEC master.dbo.usp_KillIdleBlockingSession $procArgs") }

KillRun '@IdleMinutes = 30'
Check '閒置未滿 30 分鐘 -> 不 KILL' (Alive $A)

KillRun '@IdleMinutes = 0, @WhatIf = 1'
Check 'WhatIf 模式 -> 不 KILL' (Alive $A)
Check 'WhatIf 模式 -> 有寫入 WHATIF 紀錄' ((Run $m "SELECT COUNT(*) FROM master.dbo.IdleSessionKillLog WHERE Action='WHATIF' AND SessionId=$spidA").Rows[0][0] -eq 1)

KillRun "@IdleMinutes = 0, @DatabaseList = N'otherdb'"
Check '資料庫不在 @DatabaseList -> 不 KILL' (Alive $A)

KillRun "@IdleMinutes = 0, @DatabaseList = N'ctrlmdb, testdb'"
Check '符合條件 -> 阻塞源 A 被 KILL' (-not (Alive $A))
Check '閒置但未阻塞的 C 不受影響' (Alive $C)
Check '閒置無交易的 D 不受影響' (Alive $D)
Check '被阻塞的 B 在 A 被 KILL 後完成' ($asyncB.AsyncWaitHandle.WaitOne(10000))
if ($asyncB.IsCompleted) { try { [void]$cmdB.EndExecuteNonQuery() } catch { } }
Check 'KILLED 紀錄已寫入' ((Run $m "SELECT COUNT(*) FROM master.dbo.IdleSessionKillLog WHERE Action='KILLED' AND SessionId=$spidA").Rows[0][0] -eq 1)

# 預設參數 (實際 Job 呼叫方式) 可正常執行
KillRun '@IdleMinutes = 30, @DatabaseList = NULL, @WhatIf = 0'
Check '預設呼叫方式可正常執行' $true

# Job 手動執行
[void](Run $m "EXEC msdb.dbo.sp_start_job N'DBA - Kill Idle Blocking Sessions'")
Start-Sleep 5
$h = Run $m "SELECT TOP 1 run_status FROM msdb.dbo.sysjobhistory h JOIN msdb.dbo.sysjobs j ON j.job_id=h.job_id WHERE j.name=N'DBA - Kill Idle Blocking Sessions' AND h.step_id=0 ORDER BY h.instance_id DESC"
Check 'Agent Job 手動執行成功' ($h.Rows.Count -eq 1 -and $h.Rows[0][0] -eq 1)

foreach ($c in $B, $C, $D, $m) { try { $c.Dispose() } catch { } }
if ($script:fail -gt 0) { Write-Host "FAILED: $script:fail" -ForegroundColor Red; exit 1 }
Write-Host 'ALL PASSED' -ForegroundColor Green
