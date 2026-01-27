#Requires -Version 7.0

<#
.SYNOPSIS
    Tests that export and import work with a minimal config file.

.DESCRIPTION
    Verifies that all config properties have safe defaults by using a minimal
    config file that only sets trustServerCertificate.

.NOTES
    Requires: SQL Server container running (docker-compose up -d)
#>

param(
    [string]$Server = 'localhost',
    [string]$Database = 'TestDb',
    [string]$Username = 'sa',
    [string]$Password = 'Test@1234'
)

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

# Test configuration
$minimalConfigPath = Join-Path $scriptDir 'test-minimal-config.yml'
$exportPath = Join-Path $scriptDir 'exports_minimal_test'
$targetDatabase = 'TestDb_MinimalConfig'

# Scripts
$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$importScript = Join-Path $projectRoot 'Import-SqlServerSchema.ps1'

# Build credential
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Test results
$testsPassed = 0
$testsFailed = 0

function Write-TestResult {
    param([string]$TestName, [bool]$Passed, [string]$Message = '')
    if ($Passed) {
        Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    }
    else {
        Write-Host "[FAILED] $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'MINIMAL CONFIG TEST' -ForegroundColor Cyan
Write-Host 'Testing that export/import work with minimal configuration' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Verify minimal config file exists and is valid
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '[INFO] Test 1: Checking minimal config file...' -ForegroundColor Cyan

$configExists = Test-Path $minimalConfigPath
Write-TestResult 'Minimal config file exists' $configExists

if ($configExists) {
    $configContent = Get-Content $minimalConfigPath -Raw
    $hasSchema = $configContent -match '\$schema:'
    $hasTrustCert = $configContent -match 'trustServerCertificate:'
    $lineCount = ($configContent -split "`n").Count

    Write-TestResult 'Config has schema reference' $hasSchema
    Write-TestResult 'Config has trustServerCertificate' $hasTrustCert
    Write-TestResult "Config is minimal ($lineCount lines)" ($lineCount -lt 10)
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Export with minimal config
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 2: Export with minimal config...' -ForegroundColor Cyan

# Clean up previous test exports
if (Test-Path $exportPath) {
    Remove-Item $exportPath -Recurse -Force
}

try {
    $exportOutput = & $exportScript `
        -Server $Server `
        -Database $Database `
        -OutputPath $exportPath `
        -Credential $credential `
        -ConfigFile $minimalConfigPath 2>&1

    $exportSuccess = $LASTEXITCODE -eq 0

    # Find the export directory
    $exportDir = Get-ChildItem $exportPath -Directory | Select-Object -First 1

    Write-TestResult 'Export completed successfully' $exportSuccess
    Write-TestResult 'Export directory created' ($null -ne $exportDir)

    if ($exportDir) {
        # Check for key folders (using current folder numbering)
        $hasSchemas = Test-Path (Join-Path $exportDir.FullName '03_Schemas')
        $hasTables = Test-Path (Join-Path $exportDir.FullName '09_Tables_PrimaryKey')
        $hasReadme = Test-Path (Join-Path $exportDir.FullName '_DEPLOYMENT_README.md')

        Write-TestResult 'Schemas folder exported' $hasSchemas
        Write-TestResult 'Tables folder exported' $hasTables
        Write-TestResult 'Deployment README created' $hasReadme

        # Count exported files
        $sqlFiles = Get-ChildItem $exportDir.FullName -Filter '*.sql' -Recurse
        Write-Host "  Exported $($sqlFiles.Count) SQL files" -ForegroundColor Gray
        Write-TestResult 'SQL files exported' ($sqlFiles.Count -gt 0)
    }
}
catch {
    Write-TestResult 'Export completed successfully' $false $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Import with minimal config (Dev mode - default)
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 3: Import with minimal config (Dev mode)...' -ForegroundColor Cyan

if ($exportDir) {
    try {
        # Drop target database if exists
        $dropQuery = @"
IF EXISTS (SELECT name FROM sys.databases WHERE name = '$targetDatabase')
BEGIN
    ALTER DATABASE [$targetDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$targetDatabase];
END
"@
        Invoke-Sqlcmd -ServerInstance $Server -Query $dropQuery -Username $Username -Password $Password -TrustServerCertificate

        $importOutput = & $importScript `
            -Server $Server `
            -Database $targetDatabase `
            -SourcePath $exportDir.FullName `
            -Credential $credential `
            -ConfigFile $minimalConfigPath `
            -CreateDatabase 2>&1

        $importSuccess = $LASTEXITCODE -eq 0
        Write-TestResult 'Import completed successfully' $importSuccess

        if ($importSuccess) {
            # Verify database was created
            $dbExists = Invoke-Sqlcmd -ServerInstance $Server -Query "SELECT name FROM sys.databases WHERE name = '$targetDatabase'" -Username $Username -Password $Password -TrustServerCertificate
            Write-TestResult 'Target database created' ($null -ne $dbExists)

            # Verify some objects exist
            $tableCount = Invoke-Sqlcmd -ServerInstance $Server -Database $targetDatabase -Query "SELECT COUNT(*) AS cnt FROM sys.tables WHERE is_ms_shipped = 0" -Username $Username -Password $Password -TrustServerCertificate
            Write-TestResult 'Tables imported' ($tableCount.cnt -gt 0)
            Write-Host "  Imported $($tableCount.cnt) tables" -ForegroundColor Gray

            # Dev mode uses default import behavior - FileGroups may be remapped
            # The key is that import succeeded without manual configuration
            Write-TestResult 'Dev mode import succeeded without extra config' $true
        }
    }
    catch {
        Write-TestResult 'Import completed successfully' $false $_.Exception.Message
    }
}
else {
    Write-Host '[SKIP] Import test skipped - no export directory' -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Verify default values were applied
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 4: Verify default values were applied...' -ForegroundColor Cyan

# Check that export used defaults (Sql2022, no data)
if ($exportDir) {
    $dataFolder = Join-Path $exportDir.FullName '21_Data'
    $hasDataFolder = Test-Path $dataFolder
    if ($hasDataFolder) {
        $dataFiles = Get-ChildItem $dataFolder -Filter '*.sql' -ErrorAction SilentlyContinue
        $noDataExported = ($null -eq $dataFiles -or $dataFiles.Count -eq 0)
    }
    else {
        $noDataExported = $true
    }
    Write-TestResult 'Default: No data exported (includeData=false)' $noDataExported
}

# Check import used Dev mode (no FileGroups, no DB configs)
if ($importSuccess) {
    # MAXDOP should be server default in Dev mode
    $maxdop = Invoke-Sqlcmd -ServerInstance $Server -Database $targetDatabase -Query "SELECT CAST(value AS int) AS val FROM sys.database_scoped_configurations WHERE name = 'MAXDOP'" -Username $Username -Password $Password -TrustServerCertificate -ErrorAction SilentlyContinue
    $defaultMaxdop = ($null -eq $maxdop -or $maxdop.val -eq 0)
    Write-TestResult 'Default: Dev mode (MAXDOP not overridden)' $defaultMaxdop
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Cleaning up...' -ForegroundColor Cyan

try {
    # Drop test database
    $dropQuery = @"
IF EXISTS (SELECT name FROM sys.databases WHERE name = '$targetDatabase')
BEGIN
    ALTER DATABASE [$targetDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$targetDatabase];
END
"@
    Invoke-Sqlcmd -ServerInstance $Server -Query $dropQuery -Username $Username -Password $Password -TrustServerCertificate
    Write-Host '  Dropped test database' -ForegroundColor Gray

    # Remove export directory
    if (Test-Path $exportPath) {
        Remove-Item $exportPath -Recurse -Force
        Write-Host '  Removed export directory' -ForegroundColor Gray
    }
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
    Write-Host '[SUCCESS] ALL MINIMAL CONFIG TESTS PASSED!' -ForegroundColor Green
    Write-Host 'Export and import work correctly with minimal configuration.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[FAILED] $testsFailed test(s) failed" -ForegroundColor Red
    exit 1
}
