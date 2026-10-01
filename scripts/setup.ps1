param(
    [string]$Server = 'localhost',
    [string]$BackupPath = 'D:\An\dl newest\CompanyX.bak',
    [string]$SourceDatabase = 'CompanyX_BI_Source',
    [string]$WarehouseDatabase = 'CompanyX_BI_DW',
    [switch]$SkipRestore
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path $PSScriptRoot -Parent
foreach ($dbName in @($SourceDatabase,$WarehouseDatabase)) {
    if ($dbName -notmatch '^CompanyX_BI_[A-Za-z0-9_]+$') { throw 'Use a dedicated CompanyX_BI_ database name.' }
}
if ($SourceDatabase -eq $WarehouseDatabase) { throw 'Source and warehouse must differ.' }
if ($BackupPath.Contains("'")) { throw 'A backup path containing apostrophes is unsupported by this SQLCMD script.' }
$sqlFiles = @('01_database.sql','02_etl.sql','03_marts.sql')
$env:BackupPath = $BackupPath
if (-not $SkipRestore) { $sqlFiles = @('00_restore_source.sql') + $sqlFiles }
foreach ($sqlFile in $sqlFiles) {
    Write-Output "Applying $sqlFile"
    & sqlcmd -S $Server -E -C -b -l 15 -f 65001 -i (Join-Path $projectRoot "sql\$sqlFile") -v "SourceDatabase=$SourceDatabase" "WarehouseDatabase=$WarehouseDatabase"
    if ($LASTEXITCODE -ne 0) { throw "SQL deployment failed: $sqlFile" }
}
Write-Output 'SQL deployment complete. Run .venv\Scripts\python.exe -X utf8 scripts\run.py etl --full.'
