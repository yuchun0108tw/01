/*
* File:          KillIdleBlockingSession.sql
* Main Function: 自動判斷並 KILL「閒置超過 N 分鐘、且正在 Lock(阻塞)其他 Session」的連線，
*                並建立 SQL Server Agent Job，每 20 分鐘自動執行一次。
* Compatible:    SQL Server 2016 / 2019 / 2022 (僅使用 2012+ 皆有之 DMV，不使用 sys.sysprocesses)
* Permission:    執行者需具備 sysadmin (或 ALTER ANY CONNECTION + VIEW SERVER STATE + 建立 Job 權限)
*
* 判斷條件 (須同時成立才會 KILL)：
*   1. 使用者連線 (is_user_process = 1)，且非自己
*   2. Session 狀態為 sleeping，且目前沒有任何執行中的 request (AWAITING COMMAND)
*   3. 最後一次請求結束時間 last_request_end_time 早於 @IdleMinutes 分鐘前
*   4. 目前正在阻塞其他 Session (有其他 request 的 blocking_session_id = 此 session)
*   5. (可選) 所在資料庫在 @DatabaseList 內；NULL 代表所有資料庫
*
* 使用方式：整份腳本直接執行即可 (可重複執行，會覆蓋舊的 Procedure 與 Job)。
*/

USE master;
GO

/* ===================================================================
   1. 執行紀錄表
   =================================================================== */
IF OBJECT_ID(N'dbo.IdleSessionKillLog', N'U') IS NULL
BEGIN
    CREATE TABLE dbo.IdleSessionKillLog
    (
        LogId                BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_IdleSessionKillLog PRIMARY KEY,
        LogTime              DATETIME2(0)   NOT NULL CONSTRAINT DF_IdleSessionKillLog_LogTime DEFAULT (SYSDATETIME()),
        SessionId            INT            NOT NULL,
        LoginName            NVARCHAR(128)  NULL,
        HostName             NVARCHAR(128)  NULL,
        ProgramName          NVARCHAR(128)  NULL,
        DatabaseName         SYSNAME        NULL,
        LastRequestEndTime   DATETIME       NULL,
        IdleMinutes          INT            NULL,
        OpenTranCount        INT            NULL,
        BlockedSessionCount  INT            NULL,
        Action               VARCHAR(20)    NOT NULL,   -- KILLED / WHATIF / FAILED
        ErrorMessage         NVARCHAR(4000) NULL
    );
END
GO

/* ===================================================================
   2. 主要 Procedure
   =================================================================== */
IF OBJECT_ID(N'dbo.usp_KillIdleBlockingSession', N'P') IS NOT NULL
    DROP PROCEDURE dbo.usp_KillIdleBlockingSession;
GO

CREATE PROCEDURE dbo.usp_KillIdleBlockingSession
    @IdleMinutes   INT            = 30,    -- 閒置門檻 (分鐘)
    @DatabaseList  NVARCHAR(MAX)  = NULL,  -- 限定資料庫，逗號分隔，例如 N'ctrlmdb,emdb'；NULL = 全部資料庫
    @WhatIf        BIT            = 0,     -- 1 = 只列出/記錄，不實際 KILL
    @LogRetainDays INT            = 90     -- 紀錄保留天數
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Candidates TABLE
    (
        session_id           INT           NOT NULL PRIMARY KEY,
        login_name           NVARCHAR(128) NULL,
        host_name            NVARCHAR(128) NULL,
        program_name         NVARCHAR(128) NULL,
        database_name        SYSNAME       NULL,
        last_request_end     DATETIME      NOT NULL,
        open_tran_count      INT           NULL,
        blocked_count        INT           NULL
    );

    DECLARE @Threshold DATETIME = DATEADD(MINUTE, -@IdleMinutes, GETDATE());
    DECLARE @Db NVARCHAR(MAX) = CASE WHEN @DatabaseList IS NULL THEN NULL
                                     ELSE N',' + REPLACE(@DatabaseList, N' ', N'') + N',' END;

    INSERT INTO @Candidates
        (session_id, login_name, host_name, program_name, database_name, last_request_end, open_tran_count, blocked_count)
    SELECT  s.session_id, s.login_name, s.host_name, s.program_name,
            DB_NAME(s.database_id), s.last_request_end_time, s.open_transaction_count,
            b.blocked_count
    FROM    sys.dm_exec_sessions AS s
    CROSS APPLY
            (   SELECT COUNT(DISTINCT r.session_id) AS blocked_count
                FROM   sys.dm_exec_requests AS r
                WHERE  r.blocking_session_id = s.session_id
                  AND  r.session_id <> s.session_id ) AS b
    WHERE   s.is_user_process = 1
      AND   s.session_id <> @@SPID
      AND   s.status = N'sleeping'
      AND   NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r0 WHERE r0.session_id = s.session_id)
      AND   s.last_request_end_time < @Threshold
      AND   b.blocked_count > 0                                  -- 正在 Lock 其他 Session
      AND   (@Db IS NULL OR @Db LIKE N'%,' + DB_NAME(s.database_id) + N',%');

    DECLARE @sid INT, @login NVARCHAR(128), @host NVARCHAR(128), @prog NVARCHAR(128),
            @dbname SYSNAME, @lastEnd DATETIME, @tran INT, @blocked INT,
            @sql NVARCHAR(50), @err NVARCHAR(4000);

    DECLARE curKill CURSOR LOCAL FAST_FORWARD READ_ONLY FOR
        SELECT session_id, login_name, host_name, program_name, database_name,
               last_request_end, open_tran_count, blocked_count
        FROM   @Candidates
        ORDER  BY session_id;

    OPEN curKill;
    FETCH NEXT FROM curKill INTO @sid, @login, @host, @prog, @dbname, @lastEnd, @tran, @blocked;

    WHILE @@FETCH_STATUS = 0
    BEGIN
        -- KILL 前再確認一次：仍是同一段閒置 (last_request_end_time 未變)、仍在阻塞他人
        IF EXISTS (SELECT 1 FROM sys.dm_exec_sessions AS s
                   WHERE s.session_id = @sid
                     AND s.status = N'sleeping'
                     AND s.last_request_end_time = @lastEnd
                     AND NOT EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r WHERE r.session_id = s.session_id)
                     AND EXISTS (SELECT 1 FROM sys.dm_exec_requests AS r
                                 WHERE r.blocking_session_id = s.session_id AND r.session_id <> s.session_id))
        BEGIN
            SET @err = NULL;

            IF @WhatIf = 1
            BEGIN
                PRINT N'[WhatIf] KILL ' + CAST(@sid AS NVARCHAR(10));
            END
            ELSE
            BEGIN
                BEGIN TRY
                    SET @sql = N'KILL ' + CAST(@sid AS NVARCHAR(10));
                    PRINT @sql;
                    EXEC (@sql);
                END TRY
                BEGIN CATCH
                    SET @err = ERROR_MESSAGE();
                END CATCH
            END

            INSERT INTO dbo.IdleSessionKillLog
                (SessionId, LoginName, HostName, ProgramName, DatabaseName, LastRequestEndTime,
                 IdleMinutes, OpenTranCount, BlockedSessionCount, Action, ErrorMessage)
            VALUES
                (@sid, @login, @host, @prog, @dbname, @lastEnd,
                 DATEDIFF(MINUTE, @lastEnd, GETDATE()), @tran, @blocked,
                 CASE WHEN @WhatIf = 1 THEN 'WHATIF' WHEN @err IS NULL THEN 'KILLED' ELSE 'FAILED' END,
                 @err);
        END

        FETCH NEXT FROM curKill INTO @sid, @login, @host, @prog, @dbname, @lastEnd, @tran, @blocked;
    END

    CLOSE curKill;
    DEALLOCATE curKill;

    DELETE FROM dbo.IdleSessionKillLog WHERE LogTime < DATEADD(DAY, -@LogRetainDays, SYSDATETIME());
END
GO

/* ===================================================================
   3. SQL Server Agent Job：每 20 分鐘執行一次
      (SQL Server Express 無 SQL Agent，請改用 Windows 排程 / k8s CronJob 呼叫
       EXEC master.dbo.usp_KillIdleBlockingSession;)
   =================================================================== */
USE msdb;
GO

DECLARE @JobName SYSNAME = N'DBA - Kill Idle Blocking Sessions';

IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = @JobName)
    EXEC msdb.dbo.sp_delete_job @job_name = @JobName, @delete_unused_schedule = 1;

EXEC msdb.dbo.sp_add_job
     @job_name    = @JobName,
     @enabled     = 1,
     @description = N'每 20 分鐘檢查，KILL 閒置(sleeping)超過 30 分鐘且正在阻塞其他 Session 的連線';

EXEC msdb.dbo.sp_add_jobstep
     @job_name      = @JobName,
     @step_name     = N'Kill idle blocking sessions',
     @subsystem     = N'TSQL',
     @database_name = N'master',
     -- 限定資料庫範例：@DatabaseList = N''ctrlmdb,emdb''
     @command       = N'EXEC dbo.usp_KillIdleBlockingSession @IdleMinutes = 30, @DatabaseList = NULL, @WhatIf = 0;',
     @on_success_action = 1,
     @on_fail_action    = 2;

EXEC msdb.dbo.sp_add_jobschedule
     @job_name             = @JobName,
     @name                 = N'Every 20 minutes',
     @enabled              = 1,
     @freq_type            = 4,      -- 每天
     @freq_interval        = 1,
     @freq_subday_type     = 4,      -- 以「分鐘」為單位
     @freq_subday_interval = 20,     -- 每 20 分鐘
     @active_start_time    = 0;      -- 00:00:00 起

EXEC msdb.dbo.sp_add_jobserver @job_name = @JobName, @server_name = N'(local)';
GO
