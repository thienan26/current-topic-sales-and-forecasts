-- Run in SQLCMD mode. Defaults are supplied by scripts/setup.ps1.
-- This script never overwrites an existing database or uses WITH REPLACE.
USE master;
GO
IF DB_ID(N'$(SourceDatabase)') IS NULL
BEGIN
    DECLARE @data nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultDataPath'));
    DECLARE @log nvarchar(4000) = CONVERT(nvarchar(4000), SERVERPROPERTY('InstanceDefaultLogPath'));
    DECLARE @mdf nvarchar(4000) = @data + N'$(SourceDatabase).mdf';
    DECLARE @ldf nvarchar(4000) = @log + N'$(SourceDatabase)_log.ldf';
    RESTORE DATABASE [$(SourceDatabase)] FROM DISK=N'$(BackupPath)'
      WITH MOVE N'AdventureWorks2022' TO @mdf,
           MOVE N'AdventureWorks2022_log' TO @ldf, RECOVERY, STATS=10;
END
ELSE PRINT N'Existing source retained. No restore performed.';
GO
