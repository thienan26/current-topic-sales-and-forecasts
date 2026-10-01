param([string]$Server='localhost',[string]$WarehouseDatabase='CompanyX_BI_DW',[switch]$Enable)
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
if ($WarehouseDatabase -notmatch '^CompanyX_BI_[A-Za-z0-9_]+$') { throw 'Use a dedicated CompanyX_BI_ warehouse.' }
$scriptPath=Join-Path $projectRoot 'scripts\run_pipeline.ps1'
if ($scriptPath.Contains('"')) { throw 'Invalid script path' }
# Jobs are created disabled unless -Enable is explicitly selected by the operator.
# Agent needs an account/proxy with SQL permissions and read/execute access to this project.
$jobs=@(
    @{Name='CompanyX BI - 5 minute ETL'; Subsystem='TSQL'; Command='EXEC ctl.LoadSales @FullReconcile=0;'; Frequency=4; Interval=1; Subday=4; SubdayInterval=5; Start=0},
    @{Name='CompanyX BI - nightly reconciliation'; Subsystem='TSQL'; Command='EXEC ctl.LoadSales @FullReconcile=1;'; Frequency=4; Interval=1; Subday=1; SubdayInterval=0; Start=10000},
    @{Name='CompanyX BI - daily forecast'; Subsystem='CmdExec'; Command="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode score"; Frequency=4; Interval=1; Subday=1; SubdayInterval=0; Start=60000},
    @{Name='CompanyX BI - weekly training'; Subsystem='CmdExec'; Command="powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`" -Mode train"; Frequency=8; Interval=2; Subday=1; SubdayInterval=0; Start=50000}
)
$connection=New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=msdb;Integrated Security=True;Encrypt=True;TrustServerCertificate=True"
$connection.Open()
try {
    foreach ($job in $jobs) {
        $command=$connection.CreateCommand()
        $command.CommandText=@'
IF EXISTS(SELECT 1 FROM msdb.dbo.sysjobs WHERE name=@name)
BEGIN
    PRINT 'Existing job retained; review settings in SSMS.';
    RETURN;
END;
SET XACT_ABORT ON;
BEGIN TRANSACTION;
DECLARE @jobid uniqueidentifier;
EXEC msdb.dbo.sp_add_job @job_name=@name,@enabled=@enabled,@job_id=@jobid OUTPUT;
EXEC msdb.dbo.sp_add_jobstep @job_id=@jobid,@step_name=N'Run pipeline',@subsystem=@subsystem,
     @command=@cmd,@database_name=@db,@retry_attempts=2,@retry_interval=1;
EXEC msdb.dbo.sp_add_jobschedule @job_id=@jobid,@name=@name,@freq_type=@freq,@freq_interval=@interval,
     @freq_subday_type=@subday,@freq_subday_interval=@subinterval,@active_start_time=@start,@freq_recurrence_factor=1;
EXEC msdb.dbo.sp_add_jobserver @job_id=@jobid;
COMMIT;
'@
        [void]$command.Parameters.AddWithValue('@name',$job.Name)
        [void]$command.Parameters.AddWithValue('@enabled',[int]$Enable.IsPresent)
        [void]$command.Parameters.AddWithValue('@subsystem',$job.Subsystem)
        [void]$command.Parameters.AddWithValue('@cmd',$job.Command)
        [void]$command.Parameters.AddWithValue('@db',$WarehouseDatabase)
        [void]$command.Parameters.AddWithValue('@freq',$job.Frequency)
        [void]$command.Parameters.AddWithValue('@interval',$job.Interval)
        [void]$command.Parameters.AddWithValue('@subday',$job.Subday)
        [void]$command.Parameters.AddWithValue('@subinterval',$job.SubdayInterval)
        [void]$command.Parameters.AddWithValue('@start',$job.Start)
        [void]$command.ExecuteNonQuery()
        Write-Output "Checked $($job.Name); new jobs enabled=$($Enable.IsPresent)"
    }
} finally { $connection.Dispose() }
