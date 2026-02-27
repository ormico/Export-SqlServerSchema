#Requires -Version 7.0

<#
.SYNOPSIS
    Unit tests for -ValidateOnly mode in Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1.

.DESCRIPTION
    These tests validate the offline validation behavior without requiring a SQL Server connection.
    Tests cover config file validation, path accessibility checks, environment variable checks,
    and import folder structure parsing.

.NOTES
    Does NOT require a SQL Server connection. All tests run locally.
#>

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$importScript = Join-Path $projectRoot 'Import-SqlServerSchema.ps1'

$testsPassed = 0
$testsFailed = 0

function Write-TestResult {
    param([string]$TestName, [bool]$Passed, [string]$Message = '')
    if ($Passed) {
        Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    }
    else {
        Write-Host "[FAILED]  $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "          $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: Create temporary test fixtures
# ─────────────────────────────────────────────────────────────────────────────

$baseTempDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$tempDir = Join-Path $baseTempDir "validate-only-tests-$(New-Guid)"
$null = New-Item $tempDir -ItemType Directory -Force

# Valid minimal config file
$validConfigPath = Join-Path $tempDir 'valid-config.yml'
Set-Content $validConfigPath -Value @'
trustServerCertificate: true
connectionTimeout: 30
commandTimeout: 300
'@

# Config with unknown keys (should produce warnings only)
$unknownKeysConfigPath = Join-Path $tempDir 'unknown-keys-config.yml'
Set-Content $unknownKeysConfigPath -Value @'
trustServerCertificate: true
unknownTopLevelKey: somevalue
'@

# Config with invalid targetSqlVersion enum (should produce error)
$invalidEnumConfigPath = Join-Path $tempDir 'invalid-enum-config.yml'
Set-Content $invalidEnumConfigPath -Value @'
targetSqlVersion: Sql2099
'@

# Config with invalid importMode (should produce error)
$invalidImportModeConfigPath = Join-Path $tempDir 'invalid-importmode-config.yml'
Set-Content $invalidImportModeConfigPath -Value @'
importMode: NotARealMode
'@

# Writable output directory
$writableOutputDir = Join-Path $tempDir 'output-writable'
$null = New-Item $writableOutputDir -ItemType Directory -Force

# A fake export folder with proper structure for ValidateOnly import tests
$fakeExportDir = Join-Path $tempDir 'fake-export'
$null = New-Item $fakeExportDir -ItemType Directory -Force
foreach ($subDir in @('03_Schemas', '09_Tables_PrimaryKey', '14_Programmability')) {
    $null = New-Item (Join-Path $fakeExportDir $subDir) -ItemType Directory -Force
}
Set-Content (Join-Path $fakeExportDir '03_Schemas' 'dbo.schema.sql') -Value 'CREATE SCHEMA [dbo]'
Set-Content (Join-Path $fakeExportDir '09_Tables_PrimaryKey' 'dbo.Orders.table.sql') -Value @'
CREATE TABLE [dbo].[Orders] (
    [Id] INT PRIMARY KEY
)
'@
Set-Content (Join-Path $fakeExportDir '14_Programmability' 'dbo.GetOrder.proc.sql') -Value @'
CREATE PROCEDURE [dbo].[GetOrder]
AS SELECT 1
'@
Set-Content (Join-Path $fakeExportDir '_export_metadata.json') -Value '{"version":"1.0","serverName":"localhost"}'

# Export folder with CLR assemblies (no CLR config set)
$fakeClrExportDir = Join-Path $tempDir 'fake-export-clr'
$null = New-Item $fakeClrExportDir -ItemType Directory -Force
$null = New-Item (Join-Path $fakeClrExportDir '14_Programmability') -ItemType Directory -Force
Set-Content (Join-Path $fakeClrExportDir '14_Programmability' 'Assembly.MyCLR.sql') -Value @'
CREATE ASSEMBLY [MyCLR]
    AUTHORIZATION [dbo]
    FROM 0x4D5A90000300000004000000FFFF0000
    WITH PERMISSION_SET = SAFE
GO
'@
Set-Content (Join-Path $fakeClrExportDir '_export_metadata.json') -Value '{}'

# Export folder with AlwaysEncrypted keys
$fakeAeExportDir = Join-Path $tempDir 'fake-export-ae'
$null = New-Item $fakeAeExportDir -ItemType Directory -Force
$null = New-Item (Join-Path $fakeAeExportDir '01_Security') -ItemType Directory -Force
Set-Content (Join-Path $fakeAeExportDir '01_Security' 'ColumnMasterKey.sql') -Value @'
CREATE COLUMN MASTER KEY [CMK1]
WITH (KEY_STORE_PROVIDER_NAME = N'MSSQL_CERTIFICATE_STORE',
      KEY_PATH = N'CurrentUser/My/ABCDef')
GO
'@
Set-Content (Join-Path $fakeAeExportDir '_export_metadata.json') -Value '{}'

# Export folder with memory-optimized tables
$fakeMoExportDir = Join-Path $tempDir 'fake-export-mo'
$null = New-Item $fakeMoExportDir -ItemType Directory -Force
$null = New-Item (Join-Path $fakeMoExportDir '09_Tables_PrimaryKey') -ItemType Directory -Force
Set-Content (Join-Path $fakeMoExportDir '09_Tables_PrimaryKey' 'dbo.InMemoryTable.sql') -Value @'
CREATE TABLE [dbo].[InMemoryTable] (
    [Id] INT PRIMARY KEY NONCLUSTERED
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA)
'@
Set-Content (Join-Path $fakeMoExportDir '_export_metadata.json') -Value '{}'

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'VALIDATE-ONLY MODE TESTS' -ForegroundColor Cyan
Write-Host 'Testing offline validation without a SQL Server connection.' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Export -ValidateOnly Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '[INFO] Export -ValidateOnly tests' -ForegroundColor Cyan
Write-Host ''

# Test 1: Valid config + writable path → exit 0
Write-Host '[INFO] Test 1: ValidateOnly with valid config and writable output path...'
try {
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -ConfigFile $validConfigPath `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: valid config → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
    Write-TestResult 'Export ValidateOnly: output contains SUCCESS' (($output -join "`n") -match 'SUCCESS.*All validation checks passed') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: valid config → exit 0' $false $_.Exception.Message
}

# Test 2: Missing config file → exit 1
Write-Host '[INFO] Test 2: ValidateOnly with missing config file...'
try {
    $missingConfig = Join-Path $tempDir 'nonexistent-config.yml'
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -ConfigFile $missingConfig `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: missing config → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Export ValidateOnly: missing config → ERROR message' (($output -join "`n") -match 'ERROR|not found') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: missing config → exit 1' $false $_.Exception.Message
}

# Test 3: Config with invalid targetSqlVersion enum → exit 1
Write-Host '[INFO] Test 3: ValidateOnly with invalid targetSqlVersion...'
try {
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -ConfigFile $invalidEnumConfigPath `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: invalid targetSqlVersion → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Export ValidateOnly: invalid targetSqlVersion → ERROR about enum' (($output -join "`n") -match 'targetSqlVersion') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: invalid targetSqlVersion → exit 1' $false $_.Exception.Message
}

# Test 4: Config with unknown keys → exit 0 (warnings only, not errors)
Write-Host '[INFO] Test 4: ValidateOnly with unknown config keys (warnings only)...'
try {
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -ConfigFile $unknownKeysConfigPath `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: unknown keys → exit 0 (warnings only)' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
    Write-TestResult 'Export ValidateOnly: unknown keys → WARN message present' (($output -join "`n") -match 'WARN|Unknown config key') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: unknown keys → exit 0' $false $_.Exception.Message
}

# Test 5: Non-existent output path with valid parent → exit 0 (parent exists, will be created)
Write-Host '[INFO] Test 5: ValidateOnly with non-existent output path (parent valid)...'
try {
    $nonExistentOutput = Join-Path $writableOutputDir 'new-subfolder'
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $nonExistentOutput `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: non-existent output (parent OK) → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: non-existent output (parent OK) → exit 0' $false $_.Exception.Message
}

# Test 6: Output path with non-existent parent → exit 1
Write-Host '[INFO] Test 6: ValidateOnly with output path whose parent does not exist...'
try {
    $badParentOutput = Join-Path $tempDir 'nonexistent-parent-dir' 'output'
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $badParentOutput `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: bad parent path → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: bad parent path → exit 1' $false $_.Exception.Message
}

# Test 7: PasswordFromEnv pointing to a SET env var → exit 0, value not visible in output
Write-Host '[INFO] Test 7: ValidateOnly with PasswordFromEnv pointing to set env var...'
try {
    $env:VALIDATE_TEST_PASSWORD = 'secret123'
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -PasswordFromEnv 'VALIDATE_TEST_PASSWORD' `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: set PasswordFromEnv → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Export ValidateOnly: set PasswordFromEnv → masked in output' (-not (($output -join "`n") -match 'secret123')) `
        "Password was visible in output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: set PasswordFromEnv → exit 0' $false $_.Exception.Message
}
finally {
    Remove-Item Env:\VALIDATE_TEST_PASSWORD -ErrorAction SilentlyContinue
}

# Test 8: PasswordFromEnv pointing to UNSET env var → exit 0 (warning, not error)
Write-Host '[INFO] Test 8: ValidateOnly with PasswordFromEnv pointing to unset env var (warning)...'
try {
    Remove-Item Env:\VALIDATE_UNSET_VAR -ErrorAction SilentlyContinue
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -OutputPath $writableOutputDir `
        -PasswordFromEnv 'VALIDATE_UNSET_VAR' `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: unset PasswordFromEnv → exit 0 (warning)' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
    Write-TestResult 'Export ValidateOnly: unset PasswordFromEnv → WARN message' (($output -join "`n") -match 'WARN|not set') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: unset PasswordFromEnv → exit 0 warning' $false $_.Exception.Message
}

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Import -ValidateOnly Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '[INFO] Import -ValidateOnly tests' -ForegroundColor Cyan
Write-Host ''

# Test 9: Valid source path with scripts + no config → exit 0
Write-Host '[INFO] Test 9: Import ValidateOnly with valid source path...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: valid source → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
    Write-TestResult 'Import ValidateOnly: valid source → SUCCESS message' (($output -join "`n") -match 'SUCCESS.*All validation checks passed') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Import ValidateOnly: valid source → exit 0' $false $_.Exception.Message
}

# Test 10: Non-existent source path → exit 1
Write-Host '[INFO] Test 10: Import ValidateOnly with non-existent source path...'
try {
    $missingSource = Join-Path $tempDir 'nonexistent-source-dir'
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $missingSource `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: missing source → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Import ValidateOnly: missing source → ERROR message' (($output -join "`n") -match 'ERROR|does not exist|SourcePath|not found') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Import ValidateOnly: missing source → exit 1' $false $_.Exception.Message
}

# Test 11: Source path exists but has no SQL scripts → exit 1
Write-Host '[INFO] Test 11: Import ValidateOnly with empty source path...'
try {
    $emptySourceDir = Join-Path $tempDir 'empty-source'
    $null = New-Item $emptySourceDir -ItemType Directory -Force
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $emptySourceDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: empty source → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
}
catch {
    Write-TestResult 'Import ValidateOnly: empty source → exit 1' $false $_.Exception.Message
}

# Test 12: Source path shows folder structure summary
Write-Host '[INFO] Test 12: Import ValidateOnly displays folder structure...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ValidateOnly *>&1
    $outStr = $output -join "`n"
    Write-TestResult 'Import ValidateOnly: shows Schemas folder' ($outStr -match 'Schemas') `
        "Output: $outStr"
    Write-TestResult 'Import ValidateOnly: shows Tables folder' ($outStr -match 'Tables') `
        "Output: $outStr"
    Write-TestResult 'Import ValidateOnly: shows Programmability folder' ($outStr -match 'Programmability') `
        "Output: $outStr"
    Write-TestResult 'Import ValidateOnly: shows script counts' ($outStr -match '\d+\s+script') `
        "Output: $outStr"
}
catch {
    Write-TestResult 'Import ValidateOnly: folder structure display' $false $_.Exception.Message
}

# Test 13: CLR assemblies without CLR config → warning (exit 0)
Write-Host '[INFO] Test 13: Import ValidateOnly with CLR assemblies and no CLR config...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeClrExportDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    $outStr = $output -join "`n"
    Write-TestResult 'Import ValidateOnly: CLR assemblies → exit 0 (warning, not error)' ($exitCode -eq 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Import ValidateOnly: CLR assemblies → WARN about strict security' ($outStr -match 'CLR|strict security|disableStrictSecurity') `
        "Output: $outStr"
}
catch {
    Write-TestResult 'Import ValidateOnly: CLR assemblies → exit 0 with warning' $false $_.Exception.Message
}

# Test 14: AlwaysEncrypted keys without StripAlwaysEncrypted or secrets config → warning (exit 0)
Write-Host '[INFO] Test 14: Import ValidateOnly with AlwaysEncrypted keys and no AE config...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeAeExportDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    $outStr = $output -join "`n"
    Write-TestResult 'Import ValidateOnly: AE keys → exit 0 (warning)' ($exitCode -eq 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Import ValidateOnly: AE keys → WARN about AlwaysEncrypted' ($outStr -match 'AlwaysEncrypted|StripAlwaysEncrypted|encryption') `
        "Output: $outStr"
}
catch {
    Write-TestResult 'Import ValidateOnly: AE keys → exit 0 with warning' $false $_.Exception.Message
}

# Test 15: AlwaysEncrypted keys with -StripAlwaysEncrypted → no AE warning, exit 0
Write-Host '[INFO] Test 15: Import ValidateOnly with AlwaysEncrypted keys and -StripAlwaysEncrypted...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeAeExportDir `
        -StripAlwaysEncrypted `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: AE keys + StripAlwaysEncrypted → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode"
}
catch {
    Write-TestResult 'Import ValidateOnly: AE keys + StripAlwaysEncrypted → exit 0' $false $_.Exception.Message
}

# Test 16: Memory-optimized tables → warning (exit 0)
Write-Host '[INFO] Test 16: Import ValidateOnly with memory-optimized tables...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeMoExportDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    $outStr = $output -join "`n"
    Write-TestResult 'Import ValidateOnly: memory-optimized → exit 0 (warning)' ($exitCode -eq 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Import ValidateOnly: memory-optimized → WARN about filegroup' ($outStr -match 'memory.optim|MEMORY_OPTIMIZED|filegroup') `
        "Output: $outStr"
}
catch {
    Write-TestResult 'Import ValidateOnly: memory-optimized → exit 0 with warning' $false $_.Exception.Message
}

# Test 17: Invalid importMode in config → exit 1
Write-Host '[INFO] Test 17: Import ValidateOnly with invalid enum config...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ConfigFile $invalidImportModeConfigPath `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: invalid importMode → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
    Write-TestResult 'Import ValidateOnly: invalid importMode → ERROR message' (($output -join "`n") -match 'importMode') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Import ValidateOnly: invalid importMode → exit 1' $false $_.Exception.Message
}

# Test 18: Import ValidateOnly detects export metadata file
Write-Host '[INFO] Test 18: Import ValidateOnly checks for export metadata file...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ValidateOnly *>&1
    Write-TestResult 'Import ValidateOnly: reports metadata file found' (($output -join "`n") -match 'metadata') `
        "Output: $($output -join "`n")"
}
catch {
    Write-TestResult 'Import ValidateOnly: metadata detection' $false $_.Exception.Message
}

# Test 19: Import ValidateOnly with valid config file → exit 0
Write-Host '[INFO] Test 19: Import ValidateOnly with valid config...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ConfigFile $validConfigPath `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: valid config + valid source → exit 0' ($exitCode -eq 0) `
        "Exit code: $exitCode"
}
catch {
    Write-TestResult 'Import ValidateOnly: valid config + valid source → exit 0' $false $_.Exception.Message
}

# Test 20: Import ValidateOnly with missing config → exit 1
Write-Host '[INFO] Test 20: Import ValidateOnly with missing config file...'
try {
    $missingConfig = Join-Path $tempDir 'nonexistent.yml'
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'localhost' `
        -SourcePath $fakeExportDir `
        -ConfigFile $missingConfig `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: missing config → exit 1' ($exitCode -ne 0) `
        "Exit code: $exitCode"
}
catch {
    Write-TestResult 'Import ValidateOnly: missing config → exit 1' $false $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# Verify -ValidateOnly does NOT make server connections
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '[INFO] Verifying ValidateOnly does not require a server connection...' -ForegroundColor Cyan

# Test 21: Export ValidateOnly with unreachable server → still succeeds (no connection)
Write-Host '[INFO] Test 21: Export ValidateOnly with unreachable server → exit 0 (no connection)...'
try {
    $output = & $exportScript `
        -Database 'TestDb' `
        -Server 'nonexistent-server-that-should-not-be-reachable-xyz-99999' `
        -OutputPath $writableOutputDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Export ValidateOnly: unreachable server → exit 0 (no connection attempted)' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
}
catch {
    Write-TestResult 'Export ValidateOnly: unreachable server → exit 0' $false $_.Exception.Message
}

# Test 22: Import ValidateOnly with unreachable server → still succeeds (no connection)
Write-Host '[INFO] Test 22: Import ValidateOnly with unreachable server → exit 0 (no connection)...'
try {
    $output = & $importScript `
        -Database 'TestDb' `
        -Server 'nonexistent-server-that-should-not-be-reachable-xyz-99999' `
        -SourcePath $fakeExportDir `
        -ValidateOnly *>&1
    $exitCode = $LASTEXITCODE
    Write-TestResult 'Import ValidateOnly: unreachable server → exit 0 (no connection attempted)' ($exitCode -eq 0) `
        "Exit code: $exitCode`nOutput: $($output -join "`n")"
}
catch {
    Write-TestResult 'Import ValidateOnly: unreachable server → exit 0' $false $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# Test with existing CLR test fixtures
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '[INFO] Testing with existing CLR test fixture...' -ForegroundColor Cyan

$clrFixtureDir = Join-Path $scriptDir 'fixtures' 'clr_test'
if (Test-Path $clrFixtureDir) {
    # Test 23: CLR test fixture → should warn about CLR strict security
    Write-Host '[INFO] Test 23: ValidateOnly with CLR fixture (no CLR config)...'
    try {
        $output = & $importScript `
            -Database 'TestDb' `
            -Server 'localhost' `
            -SourcePath $clrFixtureDir `
            -ValidateOnly *>&1
        Write-TestResult 'Import ValidateOnly: CLR fixture → warns about strict security' (($output -join "`n") -match 'CLR|strict security|disableStrictSecurity') `
            "Output: $($output -join "`n")"
    }
    catch {
        Write-TestResult 'Import ValidateOnly: CLR fixture test' $false $_.Exception.Message
    }

    # Test 24: CLR test fixture with CLR-enabled config → exit 0 (CLR warning suppressed)
    $clrConfigPath = Join-Path $scriptDir 'test-clr-strict-security-enabled.yml'
    if (Test-Path $clrConfigPath) {
        Write-Host '[INFO] Test 24: ValidateOnly with CLR fixture and CLR config enabled...'
        try {
            $output = & $importScript `
                -Database 'TestDb' `
                -Server 'localhost' `
                -SourcePath $clrFixtureDir `
                -ConfigFile $clrConfigPath `
                -ValidateOnly *>&1
            $exitCode = $LASTEXITCODE
            Write-TestResult 'Import ValidateOnly: CLR fixture + CLR config → exit 0' ($exitCode -eq 0) `
                "Exit code: $exitCode"
        }
        catch {
            Write-TestResult 'Import ValidateOnly: CLR fixture + CLR config → exit 0' $false $_.Exception.Message
        }
    }
    else {
        Write-Host '[SKIP] CLR config file not found, skipping test 24' -ForegroundColor Yellow
    }
}
else {
    Write-Host '[SKIP] CLR fixture directory not found, skipping tests 23-24' -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '[INFO] Cleaning up test temp directory...' -ForegroundColor Cyan
try {
    Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "  Removed temp test dir" -ForegroundColor Gray
}
catch {
    Write-Host "  Cleanup warning: $_" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'TEST SUMMARY' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''
Write-Host "Tests Passed: $testsPassed / $($testsPassed + $testsFailed)" -ForegroundColor $(if ($testsFailed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ''

if ($testsFailed -eq 0) {
    Write-Host '[SUCCESS] ALL VALIDATE-ONLY TESTS PASSED!' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[FAILED] $testsFailed test(s) failed" -ForegroundColor Red
    exit 1
}
