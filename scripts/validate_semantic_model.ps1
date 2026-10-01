$ErrorActionPreference='Stop'
$projectRoot=Split-Path $PSScriptRoot -Parent
$app=Get-AppxPackage '*PowerBIDesktop*' | Select-Object -First 1
$bin=if ($app) { Join-Path $app.InstallLocation 'bin' } else { 'C:\Program Files\Microsoft Power BI Desktop\bin' }
foreach ($name in @('Microsoft.AnalysisServices.Server.Core.dll','Microsoft.AnalysisServices.Server.Tabular.dll','Microsoft.AnalysisServices.Server.Tabular.Json.dll')) {
    Add-Type -Path (Join-Path $bin $name)
}
$json=Get-Content -LiteralPath (Join-Path $projectRoot 'powerbi\CompanyX.SemanticModel\model.bim') -Encoding UTF8 -Raw
$db=[Microsoft.AnalysisServices.Tabular.JsonSerializer]::DeserializeDatabase($json)
Write-Output "TOM deserialized $($db.Model.Tables.Count) tables and $($db.Model.Relationships.Count) relationships."
@{tables=$db.Model.Tables.Count;relationships=$db.Model.Relationships.Count;tom_deserialization='PASS';desktop_refresh_tested=$false} |
    ConvertTo-Json | Set-Content -LiteralPath (Join-Path $projectRoot 'artifacts\semantic_model_validation.json') -Encoding UTF8
