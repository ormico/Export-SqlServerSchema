# Test Schema Exclusion on Import
# Verifies that -ExcludeSchemas parameter correctly filters out scripts by schema name

param(
    [string]$Server = 'localhost',
    [string]$Database = 'TestDb_SchemaExclude',
    [string]$Password = $env:SA_PASSWORD
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Test counters
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsRun = 0

function Write-TestResult {
    param([string]$Name, [bool]$Passed, [string]$Details = '')
    $script:TestsRun++
    if ($Passed) {
        $script:TestsPassed++
        Write-Host "  [PASS] $Name" -ForegroundColor Green
    } else {
        $script:TestsFailed++
        Write-Host "  [FAIL] $Name" -ForegroundColor Red
        if ($Details) { Write-Host "         $Details" -ForegroundColor Yellow }
    }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Schema Exclusion Import Test" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# Get password
if (-not $Password) {
    if (Test-Path '.env') {
        Get-Content '.env' | ForEach-Object {
            if ($_ -match '^SA_PASSWORD=(.+)$') {
                $Password = $matches[1]
            }
        }
    }
}

if (-not $Password) {
    Write-Host "[ERROR] SA_PASSWORD not set" -ForegroundColor Red
    exit 1
}

$securePass = ConvertTo-SecureString $Password -AsPlainText -Force
$cred = New-Object System.Management.Automation.PSCredential('sa', $securePass)

# Create connection string for sqlcmd
$connStr = "-S $Server -U sa -P $Password -C"

# Helper function to get scalar value from sqlcmd result
function Get-SqlScalarValue {
    param([array]$Result)
    if ($null -eq $Result) { return 0 }
    foreach ($line in $Result) {
        if ($line -match '^\s*(\d+)\s*$') {
            return [int]$matches[1]
        }
    }
    return 0
}

try {
    Write-Host "[PHASE 1] Setup - Create source database with multiple schemas" -ForegroundColor Yellow

    # Create a test database with objects in multiple schemas (including cdc-like schema)
    $setupSql = @"
USE master;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TestDb_SchemaSource')
    ALTER DATABASE TestDb_SchemaSource SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TestDb_SchemaSource')
    DROP DATABASE TestDb_SchemaSource;
CREATE DATABASE TestDb_SchemaSource;
GO

USE TestDb_SchemaSource;
GO

-- Create schemas
CREATE SCHEMA cdc AUTHORIZATION dbo;
GO
CREATE SCHEMA staging AUTHORIZATION dbo;
GO
CREATE SCHEMA app AUTHORIZATION dbo;
GO

-- Create tables in each schema
CREATE TABLE dbo.MainTable (Id INT PRIMARY KEY, Name NVARCHAR(50));
CREATE TABLE cdc.change_tables (Id INT PRIMARY KEY, ChangeData NVARCHAR(MAX));
CREATE TABLE staging.ImportData (Id INT PRIMARY KEY, RawData NVARCHAR(MAX));
CREATE TABLE app.UserData (Id INT PRIMARY KEY, UserName NVARCHAR(100));
GO

-- Create functions in each schema
CREATE FUNCTION dbo.fn_GetCount() RETURNS INT AS BEGIN RETURN 1; END;
GO
CREATE FUNCTION cdc.fn_cdc_get_changes() RETURNS INT AS BEGIN RETURN 1; END;
GO
CREATE FUNCTION staging.fn_ValidateData() RETURNS INT AS BEGIN RETURN 1; END;
GO
CREATE FUNCTION app.fn_GetUserCount() RETURNS INT AS BEGIN RETURN 1; END;
GO

-- Create stored procedures in each schema
CREATE PROCEDURE dbo.sp_MainProc AS SELECT 1;
GO
CREATE PROCEDURE cdc.sp_cleanup_change_tables AS SELECT 1;
GO
CREATE PROCEDURE staging.sp_ImportData AS SELECT 1;
GO
CREATE PROCEDURE app.sp_ProcessUser AS SELECT 1;
GO
"@

    # Write setup SQL to temp file
    $setupFile = Join-Path $env:TEMP 'schema_exclude_setup.sql'
    $setupSql | Out-File -FilePath $setupFile -Encoding utf8

    $result = sqlcmd @($connStr -split ' ') -i $setupFile -b 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Failed to create source database: $result" -ForegroundColor Red
        exit 1
    }
    Write-Host "  [SUCCESS] Created source database with cdc, staging, app schemas" -ForegroundColor Green

    Write-Host "`n[PHASE 2] Export source database" -ForegroundColor Yellow

    $exportPath = Join-Path $PSScriptRoot 'exports_schema_exclude'
    if (Test-Path $exportPath) { Remove-Item $exportPath -Recurse -Force }
    New-Item -ItemType Directory -Path $exportPath -Force | Out-Null

    & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
        -Server $Server `
        -Database 'TestDb_SchemaSource' `
        -OutputPath $exportPath `
        -Credential $cred 2>&1 | Out-Null

    if ($LASTEXITCODE -ne 0) {
        Write-Host "[ERROR] Export failed" -ForegroundColor Red
        exit 1
    }

    # Find the export folder
    $exportFolder = Get-ChildItem $exportPath -Directory | Select-Object -First 1
    if (-not $exportFolder) {
        Write-Host "[ERROR] No export folder found" -ForegroundColor Red
        exit 1
    }

    Write-Host "  [SUCCESS] Exported to $($exportFolder.FullName)" -ForegroundColor Green

    # Count exported files per schema
    $cdcFiles = @(Get-ChildItem $exportFolder.FullName -Recurse -Filter 'cdc.*.sql').Count
    $stagingFiles = @(Get-ChildItem $exportFolder.FullName -Recurse -Filter 'staging.*.sql').Count
    $appFiles = @(Get-ChildItem $exportFolder.FullName -Recurse -Filter 'app.*.sql').Count
    $dboFiles = @(Get-ChildItem $exportFolder.FullName -Recurse -Filter 'dbo.*.sql').Count

    Write-Host "  [INFO] Exported files: dbo=$dboFiles, app=$appFiles, cdc=$cdcFiles, staging=$stagingFiles"

    Write-Host "`n[PHASE 3] Test 1 - Import with -ExcludeSchemas cdc" -ForegroundColor Yellow

    # Drop and recreate target database
    $dropSql = @"
USE master;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
    ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
    DROP DATABASE [$Database];
CREATE DATABASE [$Database];
"@
    $dropFile = Join-Path $env:TEMP 'drop_target.sql'
    $dropSql | Out-File -FilePath $dropFile -Encoding utf8
    sqlcmd @($connStr -split ' ') -i $dropFile -b 2>&1 | Out-Null

    # Import with cdc schema excluded
    $importResult = & "$PSScriptRoot\..\Import-SqlServerSchema.ps1" `
        -Server $Server `
        -Database $Database `
        -SourcePath $exportFolder.FullName `
        -Credential $cred `
        -ExcludeSchemas 'cdc' `
        -ContinueOnError 2>&1

    Write-Host ($importResult | Out-String)

    # Check for exclusion message
    $hasExclusionMessage = $importResult -match 'Excluded.*script.*ExcludeSchemas'
    Write-TestResult -Name "Import shows exclusion message" -Passed $hasExclusionMessage

    # Verify cdc objects were NOT created
    $checkCdcSql = "USE [$Database]; SELECT COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = 'cdc'"
    $cdcObjectCount = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkCdcSql -h -1 2>&1)
    Write-TestResult -Name "cdc schema objects excluded (count=0)" -Passed ($cdcObjectCount -eq 0) -Details "Found $cdcObjectCount objects"

    # Verify app objects WERE created
    $checkAppSql = "USE [$Database]; SELECT COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = 'app'"
    $appObjectCount = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkAppSql -h -1 2>&1)
    Write-TestResult -Name "app schema objects imported (count>0)" -Passed ($appObjectCount -gt 0) -Details "Found $appObjectCount objects"

    # Verify dbo objects WERE created
    $checkDboSql = "USE [$Database]; SELECT COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = 'dbo' AND type IN ('U','P','FN')"
    $dboObjectCount = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkDboSql -h -1 2>&1)
    Write-TestResult -Name "dbo schema objects imported (count>0)" -Passed ($dboObjectCount -gt 0) -Details "Found $dboObjectCount objects"

    Write-Host "`n[PHASE 4] Test 2 - Import with multiple schemas excluded via YAML config" -ForegroundColor Yellow

    # Create config file
    $configContent = @"
import:
  continueOnError: true
  excludeSchemas:
    - cdc
    - staging
  developerMode:
    fileGroupStrategy: removeToPrimary
"@
    $configFile = Join-Path $PSScriptRoot 'test-schema-exclude-config.yml'
    $configContent | Out-File -FilePath $configFile -Encoding utf8

    # Drop and recreate target database
    sqlcmd @($connStr -split ' ') -i $dropFile -b 2>&1 | Out-Null

    # Import with config file
    $importResult2 = & "$PSScriptRoot\..\Import-SqlServerSchema.ps1" `
        -Server $Server `
        -Database $Database `
        -SourcePath $exportFolder.FullName `
        -Credential $cred `
        -ConfigFile $configFile 2>&1

    Write-Host ($importResult2 | Out-String)

    # Verify cdc objects excluded
    $cdcObjectCount2 = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkCdcSql -h -1 2>&1)
    Write-TestResult -Name "Config: cdc schema excluded" -Passed ($cdcObjectCount2 -eq 0) -Details "Found $cdcObjectCount2 objects"

    # Verify staging objects excluded
    $checkStagingSql = "USE [$Database]; SELECT COUNT(*) FROM sys.objects WHERE SCHEMA_NAME(schema_id) = 'staging'"
    $stagingObjectCount = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkStagingSql -h -1 2>&1)
    Write-TestResult -Name "Config: staging schema excluded" -Passed ($stagingObjectCount -eq 0) -Details "Found $stagingObjectCount objects"

    # Verify app objects imported
    $appObjectCount2 = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkAppSql -h -1 2>&1)
    Write-TestResult -Name "Config: app schema imported" -Passed ($appObjectCount2 -gt 0) -Details "Found $appObjectCount2 objects"

    Write-Host "`n[PHASE 5] Test 3 - Command-line overrides config" -ForegroundColor Yellow

    # Drop and recreate target database
    sqlcmd @($connStr -split ' ') -i $dropFile -b 2>&1 | Out-Null

    # Import with config (excludes cdc,staging) but command-line only excludes app
    $importResult3 = & "$PSScriptRoot\..\Import-SqlServerSchema.ps1" `
        -Server $Server `
        -Database $Database `
        -SourcePath $exportFolder.FullName `
        -Credential $cred `
        -ConfigFile $configFile `
        -ExcludeSchemas 'app' 2>&1

    Write-Host ($importResult3 | Out-String)

    # Command-line should override config - only 'app' excluded
    # cdc and staging should be imported (command-line takes precedence)
    $cdcObjectCount3 = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkCdcSql -h -1 2>&1)
    Write-TestResult -Name "Override: cdc imported (command-line wins)" -Passed ($cdcObjectCount3 -gt 0) -Details "Found $cdcObjectCount3 objects"

    $stagingObjectCount3 = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkStagingSql -h -1 2>&1)
    Write-TestResult -Name "Override: staging imported (command-line wins)" -Passed ($stagingObjectCount3 -gt 0) -Details "Found $stagingObjectCount3 objects"

    $appObjectCount3 = Get-SqlScalarValue (sqlcmd @($connStr -split ' ') -Q $checkAppSql -h -1 2>&1)
    Write-TestResult -Name "Override: app excluded by command-line" -Passed ($appObjectCount3 -eq 0) -Details "Found $appObjectCount3 objects"

} catch {
    Write-Host "[ERROR] Test failed: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    $script:TestsFailed++
} finally {
    # Cleanup
    Write-Host "`n[CLEANUP]" -ForegroundColor Yellow

    $cleanupSql = @"
USE master;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TestDb_SchemaSource')
    ALTER DATABASE TestDb_SchemaSource SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = 'TestDb_SchemaSource')
    DROP DATABASE TestDb_SchemaSource;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
    ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
    DROP DATABASE [$Database];
"@
    $cleanupFile = Join-Path $env:TEMP 'cleanup_schema_exclude.sql'
    $cleanupSql | Out-File -FilePath $cleanupFile -Encoding utf8
    sqlcmd @($connStr -split ' ') -i $cleanupFile -b 2>&1 | Out-Null

    if (Test-Path $configFile) { Remove-Item $configFile -Force }
    Write-Host "  [SUCCESS] Cleanup complete" -ForegroundColor Green
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Test Summary: $script:TestsPassed/$script:TestsRun passed" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) {
    Write-Host "[FAILED] $script:TestsFailed test(s) failed" -ForegroundColor Red
    exit 1
} else {
    Write-Host "[SUCCESS] All tests passed!" -ForegroundColor Green
    exit 0
}
