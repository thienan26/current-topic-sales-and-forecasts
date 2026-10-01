param([string]$Server='localhost',[string]$WarehouseDatabase='CompanyX_BI_DW')
$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$assembly=Get-ChildItem -LiteralPath 'C:\Windows\Microsoft.NET\assembly\GAC_MSIL\Microsoft.SqlServer.ManagedDTS' -Filter 'Microsoft.SqlServer.ManagedDTS.dll' -Recurse | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $assembly) { throw 'Install SQL Server Integration Services runtime to generate the package.' }
Add-Type -Path $assembly.FullName
$app=New-Object Microsoft.SqlServer.Dts.Runtime.Application
$package=New-Object Microsoft.SqlServer.Dts.Runtime.Package
$package.Name='CompanyX_IncrementalSales'
$package.Description='Transactional staging, validation, SCD2, fact loading, reconciliation and audit in ctl.LoadSales.'
$package.ProtectionLevel=[Microsoft.SqlServer.Dts.Runtime.DTSProtectionLevel]::DontSaveSensitive
$connection=$package.Connections.Add('ADO.NET:System.Data.SqlClient.SqlConnection, System.Data, Version=4.0.0.0, Culture=neutral, PublicKeyToken=b77a5c561934e089')
$connection.Name='Warehouse'
$connection.ConnectionString="Data Source=$Server;Initial Catalog=$WarehouseDatabase;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Application Name=CompanyX SSIS"
$taskInfo=$app.TaskInfos | Where-Object { $_.Name -eq 'Execute SQL Task' } | Select-Object -First 1
$hostTask=$package.Executables.Add($taskInfo.CreationName)
$hostTask.Name='Load sales with atomic watermark'
$task=$hostTask.InnerObject
$task.Connection=$connection.Name
$task.SqlStatementSource='EXEC ctl.LoadSales @FullReconcile=0,@LookbackDays=2;'
$task.TimeOut=300
$outDir=Join-Path $projectRoot 'ssis'
[void](New-Item -ItemType Directory -Path $outDir -Force)
$outPath=Join-Path $outDir 'CompanyX_IncrementalSales.dtsx'
$app.SaveToXml($outPath,$package,$null)
Write-Output "Created $outPath"
