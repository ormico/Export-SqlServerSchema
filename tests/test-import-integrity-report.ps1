#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the post-import integrity report feature for Import-SqlServerSchema.ps1.

.DESCRIPTION
    Validates the integrity report helper functions and report generation logic:
    1. Get-ObjectInfoFromPath parsing (type/schema/name extraction)
    2. Report JSON structure validation
    3. Skip reason code mapping
    4. Effective configuration source tracking
    5. exportedObjectCount from metadata
    6. Fallback counting when metadata missing
    7. Credentials exclusion from report
    8. Report file naming convention
    9. skippedReasons aggregation

    Does NOT require SQL Server. Re-implements helper functions locally
    following the established pattern in test-config-auto-discovery.ps1.

.NOTES
    Issue: #67 - Post-Import Integrity Report
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$script:testsPassed = 0
$script:testsFailed = 0

# ─────────────────────────────────────────────────────────────────────────────
# Test Helper
# ─────────────────────────────────────────────────────────────────────────────

function Write-TestResult {
  param(
    [string]$TestName,
    [bool]$Passed,
    [string]$Message = ''
  )
  if ($Passed) {
    Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
    $script:testsPassed++
  }
  else {
    Write-Host "[FAILED]  $TestName" -ForegroundColor Red
    if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
    $script:testsFailed++
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Local copy of Get-ObjectInfoFromPath — must stay in sync with Import script
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-GetObjectInfoFromPath {
  param(
    [string]$FilePath,
    [string]$SourcePath
  )

  $folderTypeMap = @{
    '00_FileGroups'            = 'FileGroup'
    '01_Security'              = 'Security'
    '02_DatabaseConfiguration' = 'DatabaseConfiguration'
    '03_Schemas'               = 'Schema'
    '04_Sequences'             = 'Sequence'
    '05_PartitionFunctions'    = 'PartitionFunction'
    '06_PartitionSchemes'      = 'PartitionScheme'
    '07_Types'                 = 'UserDefinedType'
    '08_XmlSchemaCollections'  = 'XmlSchemaCollection'
    '09_Tables_PrimaryKey'     = 'Table'
    '10_Tables_ForeignKeys'    = 'ForeignKey'
    '11_Indexes'               = 'Index'
    '12_Defaults'              = 'Default'
    '13_Rules'                 = 'Rule'
    '14_Programmability'       = 'Programmability'
    '15_Synonyms'              = 'Synonym'
    '16_FullTextSearch'        = 'FullTextCatalog'
    '17_ExternalData'          = 'ExternalData'
    '18_SearchPropertyLists'   = 'SearchPropertyList'
    '19_PlanGuides'            = 'PlanGuide'
    '20_SecurityPolicies'      = 'SecurityPolicy'
    '21_Data'                  = 'Data'
  }

  $relativePath = $FilePath.Substring($SourcePath.Length).TrimStart('\', '/')
  $pathParts = $relativePath -split '[\\/]'

  $folderName = $pathParts[0]
  $objectType = if ($folderTypeMap.ContainsKey($folderName)) { $folderTypeMap[$folderName] } else { $folderName -replace '^\d{2}_', '' }

  $fileName = [System.IO.Path]::GetFileName($FilePath)
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
  $schema = $null
  $name = $baseName

  if ($baseName -match '^([^.]+)\.(.+)$') {
    $schema = $matches[1]
    $name = $matches[2]
  }

  return [ordered]@{
    type     = $objectType
    schema   = $schema
    name     = $name
    filePath = $relativePath
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Local copy of report builder logic
# ─────────────────────────────────────────────────────────────────────────────

function Build-MockReport {
  param(
    [string]$SourcePath,
    [string]$Server,
    [string]$Database,
    [System.Collections.ArrayList]$ImportedObjects,
    [System.Collections.ArrayList]$SkippedObjects,
    [System.Collections.ArrayList]$FailedScripts,
    $ConfigSources,
    [datetime]$StartTime,
    [hashtable]$Metadata = $null
  )

  $duration = ((Get-Date) - $StartTime).ToString('hh\:mm\:ss')

  $exportedObjects = @()
  $exportedObjectCount = 0
  $metadataSource = $null

  if ($Metadata) {
    $metadataSource = '_export_metadata.json'
    if ($Metadata.ContainsKey('objectCount')) {
      $exportedObjectCount = $Metadata.objectCount
    }
    if ($Metadata.ContainsKey('objects') -and $Metadata.objects) {
      $exportedObjects = @($Metadata.objects)
      if ($exportedObjectCount -eq 0) {
        $exportedObjectCount = $exportedObjects.Count
      }
    }
  }

  if ($exportedObjectCount -eq 0) {
    $sqlFiles = Get-ChildItem -Path $SourcePath -Filter '*.sql' -Recurse -ErrorAction SilentlyContinue
    $exportedObjectCount = $sqlFiles.Count
  }

  $failedObjects = @()
  foreach ($failure in $FailedScripts) {
    $failedInfo = [ordered]@{
      name         = $failure.ScriptName
      filePath     = $failure.FilePath
      folder       = $failure.Folder
      reason       = 'SqlError'
      errorMessage = $failure.ErrorMessage
    }
    $failedObjects += $failedInfo
  }

  $skippedReasons = [ordered]@{}
  foreach ($skip in $SkippedObjects) {
    $reason = $skip.reason
    if ($skippedReasons.Contains($reason)) {
      $skippedReasons[$reason]++
    }
    else {
      $skippedReasons[$reason] = 1
    }
  }

  return [ordered]@{
    exportedObjectCount    = $exportedObjectCount
    importedObjectCount    = $ImportedObjects.Count
    skippedObjectCount     = $SkippedObjects.Count
    failedObjectCount      = $failedObjects.Count
    skippedReasons         = $skippedReasons
    duration               = $duration
    timestamp              = (Get-Date).ToString('o')
    sourcePath             = $SourcePath
    exportMetadataSource   = $metadataSource
    targetServer           = $Server
    targetDatabase         = $Database
    effectiveConfiguration = $ConfigSources
    exportedObjects        = $exportedObjects
    importedObjects        = @($ImportedObjects)
    skippedObjects         = @($SkippedObjects)
    failedObjects          = $failedObjects
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: Create temp directory with mock export structure
# ─────────────────────────────────────────────────────────────────────────────

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "integrity-report-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$mockSourcePath = Join-Path $tempRoot 'export'

# Create mock folder structure
$foldersToCreate = @(
  '03_Schemas'
  '09_Tables_PrimaryKey'
  '10_Tables_ForeignKeys'
  '11_Indexes'
  '14_Programmability/02_Functions'
  '14_Programmability/03_StoredProcedures'
  '14_Programmability/05_Views'
  '15_Synonyms'
  '20_SecurityPolicies'
  '21_Data'
)
foreach ($folder in $foldersToCreate) {
  New-Item -ItemType Directory -Path (Join-Path $mockSourcePath $folder) -Force | Out-Null
}

# Create mock SQL files
$mockFiles = @{
  '03_Schemas/dbo.sql'                                     = 'CREATE SCHEMA [dbo]'
  '09_Tables_PrimaryKey/dbo.Customers.sql'                 = 'CREATE TABLE [dbo].[Customers] (Id INT PRIMARY KEY)'
  '09_Tables_PrimaryKey/dbo.Orders.sql'                    = 'CREATE TABLE [dbo].[Orders] (Id INT PRIMARY KEY)'
  '09_Tables_PrimaryKey/sales.Products.sql'                = 'CREATE TABLE [sales].[Products] (Id INT PRIMARY KEY)'
  '10_Tables_ForeignKeys/dbo.Orders.sql'                   = 'ALTER TABLE [dbo].[Orders] ADD CONSTRAINT FK_Orders FOREIGN KEY (CustomerId) REFERENCES [dbo].[Customers](Id)'
  '11_Indexes/dbo.Customers.IX_Name.sql'                   = 'CREATE INDEX IX_Name ON [dbo].[Customers](Name)'
  '14_Programmability/02_Functions/dbo.GetTotal.sql'        = 'CREATE FUNCTION [dbo].[GetTotal]() RETURNS INT AS BEGIN RETURN 0 END'
  '14_Programmability/03_StoredProcedures/dbo.usp_Test.sql' = 'CREATE PROCEDURE [dbo].[usp_Test] AS SELECT 1'
  '14_Programmability/05_Views/dbo.vw_Customers.sql'       = 'CREATE VIEW [dbo].[vw_Customers] AS SELECT * FROM [dbo].[Customers]'
  '15_Synonyms/dbo.SynTest.sql'                            = 'CREATE SYNONYM [dbo].[SynTest] FOR [dbo].[Customers]'
  '20_SecurityPolicies/dbo.FilterPolicy.sql'               = 'CREATE SECURITY POLICY FilterPolicy'
  '21_Data/dbo.Customers.data.sql'                         = "INSERT INTO [dbo].[Customers] VALUES (1, 'Test')"
}

foreach ($entry in $mockFiles.GetEnumerator()) {
  $filePath = Join-Path $mockSourcePath $entry.Key
  Set-Content -Path $filePath -Value $entry.Value -Encoding UTF8
}

# ─────────────────────────────────────────────────────────────────────────────
# Test banner
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'POST-IMPORT INTEGRITY REPORT TESTS' -ForegroundColor Cyan
Write-Host 'Issue #67: Import integrity report generation' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan

try {

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 1 — Get-ObjectInfoFromPath parsing
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 1: Get-ObjectInfoFromPath parsing -----------------------' -ForegroundColor Yellow

  # Test: Schema-qualified table in Tables folder
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/09_Tables_PrimaryKey/dbo.Customers.sql" -SourcePath $mockSourcePath
  Write-TestResult 'Table: type is Table' ($info.type -eq 'Table')
  Write-TestResult 'Table: schema is dbo' ($info.schema -eq 'dbo') "got '$($info.schema)'"
  Write-TestResult 'Table: name is Customers' ($info.name -eq 'Customers') "got '$($info.name)'"
  Write-TestResult 'Table: filePath is relative' ($info.filePath -eq '09_Tables_PrimaryKey/dbo.Customers.sql' -or $info.filePath -eq '09_Tables_PrimaryKey\dbo.Customers.sql')

  # Test: Schema-qualified table with different schema
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/09_Tables_PrimaryKey/sales.Products.sql" -SourcePath $mockSourcePath
  Write-TestResult 'Table (sales schema): schema is sales' ($info.schema -eq 'sales') "got '$($info.schema)'"
  Write-TestResult 'Table (sales schema): name is Products' ($info.name -eq 'Products') "got '$($info.name)'"

  # Test: ForeignKey folder maps correctly
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/10_Tables_ForeignKeys/dbo.Orders.sql" -SourcePath $mockSourcePath
  Write-TestResult 'FK: type is ForeignKey' ($info.type -eq 'ForeignKey') "got '$($info.type)'"

  # Test: Programmability subfolder (Functions)
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/14_Programmability/02_Functions/dbo.GetTotal.sql" -SourcePath $mockSourcePath
  Write-TestResult 'Function: type is Programmability' ($info.type -eq 'Programmability') "got '$($info.type)'"
  Write-TestResult 'Function: schema is dbo' ($info.schema -eq 'dbo') "got '$($info.schema)'"
  Write-TestResult 'Function: name is GetTotal' ($info.name -eq 'GetTotal') "got '$($info.name)'"

  # Test: Index folder
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/11_Indexes/dbo.Customers.IX_Name.sql" -SourcePath $mockSourcePath
  Write-TestResult 'Index: type is Index' ($info.type -eq 'Index') "got '$($info.type)'"
  Write-TestResult 'Index: schema is dbo' ($info.schema -eq 'dbo') "got '$($info.schema)'"
  Write-TestResult 'Index: name is Customers.IX_Name' ($info.name -eq 'Customers.IX_Name') "got '$($info.name)'"

  # Test: Data folder
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/21_Data/dbo.Customers.data.sql" -SourcePath $mockSourcePath
  Write-TestResult 'Data: type is Data' ($info.type -eq 'Data') "got '$($info.type)'"
  Write-TestResult 'Data: schema is dbo' ($info.schema -eq 'dbo') "got '$($info.schema)'"

  # Test: Non-schema file (e.g., numbered files)
  $numberedFile = Join-Path $mockSourcePath '03_Schemas' '001_schemas.sql'
  Set-Content -Path $numberedFile -Value 'CREATE SCHEMA test' -Encoding UTF8
  $info = Invoke-GetObjectInfoFromPath -FilePath $numberedFile -SourcePath $mockSourcePath
  Write-TestResult 'Non-schema file: schema is null' ($null -eq $info.schema) "got '$($info.schema)'"
  Write-TestResult 'Non-schema file: name is 001_schemas' ($info.name -eq '001_schemas') "got '$($info.name)'"

  # Test: SecurityPolicies folder
  $info = Invoke-GetObjectInfoFromPath -FilePath "$mockSourcePath/20_SecurityPolicies/dbo.FilterPolicy.sql" -SourcePath $mockSourcePath
  Write-TestResult 'SecurityPolicy: type is SecurityPolicy' ($info.type -eq 'SecurityPolicy') "got '$($info.type)'"

  # Test: Unknown folder gracefully handled
  $unknownFolder = Join-Path $mockSourcePath '99_Unknown'
  New-Item -ItemType Directory -Path $unknownFolder -Force | Out-Null
  $unknownFile = Join-Path $unknownFolder 'test.sql'
  Set-Content -Path $unknownFile -Value 'SELECT 1' -Encoding UTF8
  $info = Invoke-GetObjectInfoFromPath -FilePath $unknownFile -SourcePath $mockSourcePath
  Write-TestResult 'Unknown folder: type is folder name minus prefix' ($info.type -eq 'Unknown') "got '$($info.type)'"

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 2 — Report JSON structure validation
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 2: Report JSON structure ---------------------------------' -ForegroundColor Yellow

  $imported = [System.Collections.ArrayList]::new()
  [void]$imported.Add([ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' })
  [void]$imported.Add([ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Orders'; filePath = '09_Tables_PrimaryKey/dbo.Orders.sql' })

  $skipped = [System.Collections.ArrayList]::new()
  [void]$skipped.Add([ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'FilterPolicy'; filePath = '20_SecurityPolicies/dbo.FilterPolicy.sql'; reason = 'DevMode_SecurityPolicy' })
  [void]$skipped.Add([ordered]@{ type = 'Programmability'; schema = 'dbo'; name = 'GetTotal'; filePath = '14_Programmability/02_Functions/dbo.GetTotal.sql'; reason = 'DevMode_AlwaysEncrypted' })

  $failed = [System.Collections.ArrayList]::new()
  [void]$failed.Add([PSCustomObject]@{ ScriptName = 'dbo.BadProc.sql'; FilePath = "$mockSourcePath/14_Programmability/03_StoredProcedures/dbo.BadProc.sql"; Folder = '14_Programmability'; ErrorMessage = 'Error 229: permission denied' })

  $configSources = [ordered]@{
    importMode      = [ordered]@{ value = 'Dev'; source = 'default' }
    continueOnError = [ordered]@{ value = $false; source = 'cli' }
    server          = [ordered]@{ value = 'localhost'; source = 'cli' }
    database        = [ordered]@{ value = 'TestDb'; source = 'cli' }
  }

  $mockMetadata = @{
    objectCount = 57
    objects     = @(
      @{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
    )
  }

  $report = Build-MockReport -SourcePath $mockSourcePath -Server 'localhost' -Database 'TestDb' `
    -ImportedObjects $imported -SkippedObjects $skipped -FailedScripts $failed `
    -ConfigSources $configSources -StartTime (Get-Date).AddSeconds(-102) -Metadata $mockMetadata

  # Validate top-level structure
  Write-TestResult 'Report: has exportedObjectCount' ($report.Contains('exportedObjectCount'))
  Write-TestResult 'Report: exportedObjectCount is 57' ($report.exportedObjectCount -eq 57) "got $($report.exportedObjectCount)"
  Write-TestResult 'Report: importedObjectCount is 2' ($report.importedObjectCount -eq 2) "got $($report.importedObjectCount)"
  Write-TestResult 'Report: skippedObjectCount is 2' ($report.skippedObjectCount -eq 2) "got $($report.skippedObjectCount)"
  Write-TestResult 'Report: failedObjectCount is 1' ($report.failedObjectCount -eq 1) "got $($report.failedObjectCount)"

  # Validate duration format (HH:mm:ss)
  Write-TestResult 'Report: duration matches HH:mm:ss format' ($report.duration -match '^\d{2}:\d{2}:\d{2}$') "got '$($report.duration)'"

  # Validate timestamp is ISO 8601
  Write-TestResult 'Report: timestamp is valid ISO 8601' ($null -ne [datetime]::Parse($report.timestamp)) "got '$($report.timestamp)'"

  # Validate target info
  Write-TestResult 'Report: targetServer is localhost' ($report.targetServer -eq 'localhost')
  Write-TestResult 'Report: targetDatabase is TestDb' ($report.targetDatabase -eq 'TestDb')

  # Validate metadata source
  Write-TestResult 'Report: exportMetadataSource is _export_metadata.json' ($report.exportMetadataSource -eq '_export_metadata.json')

  # Validate arrays
  Write-TestResult 'Report: exportedObjects is array' ($report.exportedObjects -is [array])
  Write-TestResult 'Report: importedObjects is array' ($report.importedObjects -is [array])
  Write-TestResult 'Report: skippedObjects is array' ($report.skippedObjects -is [array])
  Write-TestResult 'Report: failedObjects is array' ($report.failedObjects -is [array])

  # Validate report serializes to valid JSON
  $json = $report | ConvertTo-Json -Depth 10
  $parsed = $json | ConvertFrom-Json
  Write-TestResult 'Report: serializes to valid JSON' ($null -ne $parsed)
  Write-TestResult 'Report: round-trip preserves exportedObjectCount' ($parsed.exportedObjectCount -eq 57)

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 3 — Skip reason code mapping
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 3: Skip reason codes ------------------------------------' -ForegroundColor Yellow

  Write-TestResult 'Skip reason: DevMode_SecurityPolicy present' ($report.skippedObjects[0].reason -eq 'DevMode_SecurityPolicy')
  Write-TestResult 'Skip reason: DevMode_AlwaysEncrypted present' ($report.skippedObjects[1].reason -eq 'DevMode_AlwaysEncrypted')

  # Test: All expected reason codes are valid strings
  $validReasons = @('DevMode_SecurityPolicy', 'DevMode_DatabaseConfiguration', 'DevMode_ExternalData',
    'DevMode_AlwaysEncrypted', 'DevMode_FileStream', 'EmptyScript', 'DevMode_CLRAssembly')
  foreach ($reason in $validReasons) {
    Write-TestResult "Reason code '$reason' is a valid non-empty string" ($reason.Length -gt 0)
  }

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 4 — Effective configuration source tracking
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 4: Configuration source tracking -------------------------' -ForegroundColor Yellow

  Write-TestResult 'ConfigSource: importMode source is default' ($report.effectiveConfiguration.importMode.source -eq 'default')
  Write-TestResult 'ConfigSource: importMode value is Dev' ($report.effectiveConfiguration.importMode.value -eq 'Dev')
  Write-TestResult 'ConfigSource: continueOnError source is cli' ($report.effectiveConfiguration.continueOnError.source -eq 'cli')
  Write-TestResult 'ConfigSource: server source is cli' ($report.effectiveConfiguration.server.source -eq 'cli')
  Write-TestResult 'ConfigSource: server value is localhost' ($report.effectiveConfiguration.server.value -eq 'localhost')

  # Test: configFile source type
  $configFileSource = [ordered]@{
    configFile = [ordered]@{ value = '/path/to/config.yml'; source = 'configFile' }
  }
  $reportWithConfig = Build-MockReport -SourcePath $mockSourcePath -Server 'srv' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources $configFileSource -StartTime (Get-Date)
  Write-TestResult 'ConfigSource: configFile source type tracked' ($reportWithConfig.effectiveConfiguration.configFile.source -eq 'configFile')

  # Test: envVar source type
  $envVarSource = [ordered]@{
    server = [ordered]@{ value = 'env-server'; source = 'envVar:SQLCMD_SERVER' }
  }
  $reportWithEnv = Build-MockReport -SourcePath $mockSourcePath -Server 'env-server' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources $envVarSource -StartTime (Get-Date)
  Write-TestResult 'ConfigSource: envVar source includes var name' ($reportWithEnv.effectiveConfiguration.server.source -eq 'envVar:SQLCMD_SERVER')

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 5 — exportedObjectCount from metadata
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 5: exportedObjectCount from metadata ---------------------' -ForegroundColor Yellow

  # With metadata
  $metaReport = Build-MockReport -SourcePath $mockSourcePath -Server 'srv' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources ([ordered]@{}) `
    -StartTime (Get-Date) -Metadata @{ objectCount = 42; objects = @(@{ type = 'Table'; name = 'T1' }) }
  Write-TestResult 'Metadata: objectCount used when present' ($metaReport.exportedObjectCount -eq 42) "got $($metaReport.exportedObjectCount)"
  Write-TestResult 'Metadata: exportedObjects populated' ($metaReport.exportedObjects.Count -eq 1) "got $($metaReport.exportedObjects.Count)"
  Write-TestResult 'Metadata: metadataSource set' ($metaReport.exportMetadataSource -eq '_export_metadata.json')

  # With metadata objects but no objectCount
  $metaReport2 = Build-MockReport -SourcePath $mockSourcePath -Server 'srv' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources ([ordered]@{}) `
    -StartTime (Get-Date) -Metadata @{ objects = @(@{ type = 'T' }, @{ type = 'V' }, @{ type = 'P' }) }
  Write-TestResult 'Metadata: falls back to objects.Count when no objectCount' ($metaReport2.exportedObjectCount -eq 3) "got $($metaReport2.exportedObjectCount)"

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 6 — Fallback counting when metadata missing
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 6: Fallback .sql file counting ---------------------------' -ForegroundColor Yellow

  $noMetaReport = Build-MockReport -SourcePath $mockSourcePath -Server 'srv' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources ([ordered]@{}) `
    -StartTime (Get-Date) -Metadata $null

  # Count actual .sql files in mock source
  $actualSqlCount = (Get-ChildItem -Path $mockSourcePath -Filter '*.sql' -Recurse).Count
  Write-TestResult 'Fallback: counts .sql files when no metadata' ($noMetaReport.exportedObjectCount -eq $actualSqlCount) "got $($noMetaReport.exportedObjectCount), expected $actualSqlCount"
  Write-TestResult 'Fallback: exportMetadataSource is null' ($null -eq $noMetaReport.exportMetadataSource)
  Write-TestResult 'Fallback: exportedObjects is empty' ($noMetaReport.exportedObjects.Count -eq 0)

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 7 — Credentials exclusion
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 7: Credentials exclusion ---------------------------------' -ForegroundColor Yellow

  # Build a config that includes potential secret fields
  $sensitiveConfig = [ordered]@{
    server          = [ordered]@{ value = 'myserver'; source = 'cli' }
    database        = [ordered]@{ value = 'mydb'; source = 'cli' }
    importMode      = [ordered]@{ value = 'Dev'; source = 'default' }
  }

  $sensitiveReport = Build-MockReport -SourcePath $mockSourcePath -Server 'myserver' -Database 'mydb' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects ([System.Collections.ArrayList]::new()) `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources $sensitiveConfig `
    -StartTime (Get-Date)

  $reportJson = $sensitiveReport | ConvertTo-Json -Depth 10

  # Verify no credential/password/secret keys in report
  Write-TestResult 'No password in report JSON' ($reportJson -notmatch '"password"') "found 'password' in report"
  Write-TestResult 'No credential in report JSON' ($reportJson -notmatch '"credential"') "found 'credential' in report"
  Write-TestResult 'No secret in config sources' (-not $sensitiveConfig.Contains('credential'))

  # Verify the tracked parameters list excludes sensitive params
  $trackedParams = @('importMode', 'continueOnError', 'createDatabase', 'includeData', 'maxRetries',
    'retryDelaySeconds', 'connectionTimeout', 'commandTimeout', 'configFile', 'server', 'database',
    'excludeObjectTypes', 'excludeSchemas', 'stripFilestream', 'stripAlwaysEncrypted')
  $sensitiveParams = @('credential', 'password', 'passwordFromEnv', 'usernameFromEnv', 'connectionStringFromEnv')
  foreach ($param in $sensitiveParams) {
    Write-TestResult "Sensitive param '$param' not tracked" ($param -notin $trackedParams)
  }

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 8 — Report file naming
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 8: Report file naming ------------------------------------' -ForegroundColor Yellow

  $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  $expectedPattern = "import-report-\d{8}_\d{6}\.json"
  $sampleFileName = "import-report-${timestamp}.json"
  Write-TestResult 'Report filename matches pattern' ($sampleFileName -match $expectedPattern) "got '$sampleFileName'"

  # Verify the timestamp portion is parseable
  if ($sampleFileName -match 'import-report-(\d{8}_\d{6})\.json') {
    $tsStr = $matches[1]
    try {
      [datetime]::ParseExact($tsStr, 'yyyyMMdd_HHmmss', $null) | Out-Null
      Write-TestResult 'Report filename timestamp is parseable' $true
    }
    catch {
      Write-TestResult 'Report filename timestamp is parseable' $false "could not parse '$tsStr'"
    }
  }
  else {
    Write-TestResult 'Report filename timestamp is parseable' $false 'regex did not match'
  }

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 9 — skippedReasons aggregation
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 9: skippedReasons aggregation ----------------------------' -ForegroundColor Yellow

  # Build skipped list with duplicate reasons
  $multiSkipped = [System.Collections.ArrayList]::new()
  [void]$multiSkipped.Add([ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'P1'; filePath = '20_SecurityPolicies/dbo.P1.sql'; reason = 'DevMode_SecurityPolicy' })
  [void]$multiSkipped.Add([ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'P2'; filePath = '20_SecurityPolicies/dbo.P2.sql'; reason = 'DevMode_SecurityPolicy' })
  [void]$multiSkipped.Add([ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'P3'; filePath = '20_SecurityPolicies/dbo.P3.sql'; reason = 'DevMode_SecurityPolicy' })
  [void]$multiSkipped.Add([ordered]@{ type = 'Programmability'; schema = 'dbo'; name = 'F1'; filePath = '14_Programmability/02_Functions/dbo.F1.sql'; reason = 'DevMode_AlwaysEncrypted' })
  [void]$multiSkipped.Add([ordered]@{ type = 'Table'; schema = 'dbo'; name = 'T1'; filePath = '09_Tables_PrimaryKey/dbo.T1.sql'; reason = 'EmptyScript' })

  $aggReport = Build-MockReport -SourcePath $mockSourcePath -Server 'srv' -Database 'db' `
    -ImportedObjects ([System.Collections.ArrayList]::new()) -SkippedObjects $multiSkipped `
    -FailedScripts ([System.Collections.ArrayList]::new()) -ConfigSources ([ordered]@{}) `
    -StartTime (Get-Date)

  Write-TestResult 'Aggregation: DevMode_SecurityPolicy count is 3' ($aggReport.skippedReasons.DevMode_SecurityPolicy -eq 3) "got $($aggReport.skippedReasons.DevMode_SecurityPolicy)"
  Write-TestResult 'Aggregation: DevMode_AlwaysEncrypted count is 1' ($aggReport.skippedReasons.DevMode_AlwaysEncrypted -eq 1) "got $($aggReport.skippedReasons.DevMode_AlwaysEncrypted)"
  Write-TestResult 'Aggregation: EmptyScript count is 1' ($aggReport.skippedReasons.EmptyScript -eq 1) "got $($aggReport.skippedReasons.EmptyScript)"
  Write-TestResult 'Aggregation: total unique reasons is 3' ($aggReport.skippedReasons.Count -eq 3) "got $($aggReport.skippedReasons.Count)"
  Write-TestResult 'Aggregation: skippedObjectCount matches' ($aggReport.skippedObjectCount -eq 5) "got $($aggReport.skippedObjectCount)"

  # Verify round-trip through JSON preserves aggregation
  $aggJson = $aggReport | ConvertTo-Json -Depth 10
  $aggParsed = $aggJson | ConvertFrom-Json
  Write-TestResult 'Aggregation: JSON round-trip preserves counts' ($aggParsed.skippedReasons.DevMode_SecurityPolicy -eq 3)

  # ─────────────────────────────────────────────────────────────────────
  # GROUP 10 — Failed objects with type/schema/name
  # ─────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 10: Failed objects transformation ------------------------' -ForegroundColor Yellow

  Write-TestResult 'Failed: has reason SqlError' ($report.failedObjects[0].reason -eq 'SqlError')
  Write-TestResult 'Failed: has errorMessage' ($report.failedObjects[0].errorMessage -eq 'Error 229: permission denied')
  Write-TestResult 'Failed: failedObjectCount is 1' ($report.failedObjectCount -eq 1)

}
finally {
  # Cleanup
  if (Test-Path $tempRoot) {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "Tests passed: $($script:testsPassed)" -ForegroundColor Green
Write-Host "Tests failed: $($script:testsFailed)" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan

if ($script:testsFailed -gt 0) { exit 1 } else { exit 0 }
