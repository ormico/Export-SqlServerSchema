#Requires -Version 7.0

<#
.SYNOPSIS
    Tests that FileGroups can be imported with fileGroupStrategy settings.

.DESCRIPTION
    Verifies that fileGroupStrategy: autoRemap in a minimal config
    correctly imports FileGroups during Dev mode import.

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
$fileGroupsConfigPath = Join-Path $scriptDir 'test-minimal-filegroups.yml'
$exportPath = Join-Path $scriptDir 'exports_filegroups_test'
$targetDatabaseAutoRemap = 'TestDb_AutoRemap'
$targetDatabaseExplicitFG = 'TestDb_ExplicitFG'

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

function Get-FileGroupCount {
    param([string]$DbName)
    $result = Invoke-Sqlcmd -ServerInstance $Server -Database $DbName `
        -Query "SELECT COUNT(*) AS cnt FROM sys.filegroups WHERE name != 'PRIMARY'" `
        -Username $Username -Password $Password -TrustServerCertificate
    return $result.cnt
}

function Drop-TestDatabase {
    param([string]$DbName)
    $dropQuery = @"
IF EXISTS (SELECT name FROM sys.databases WHERE name = '$DbName')
BEGIN
    ALTER DATABASE [$DbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DbName];
END
"@
    Invoke-Sqlcmd -ServerInstance $Server -Query $dropQuery -Username $Username -Password $Password -TrustServerCertificate
}

Write-Host '' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'FILEGROUP STRATEGY TEST' -ForegroundColor Cyan
Write-Host 'Testing fileGroupStrategy: autoRemap with minimal config' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Setup: Check source database has FileGroups
# ─────────────────────────────────────────────────────────────────────────────
Write-Host '[INFO] Setup: Checking source database...' -ForegroundColor Cyan

$sourceFGCount = Invoke-Sqlcmd -ServerInstance $Server -Database $Database `
    -Query "SELECT COUNT(*) AS cnt FROM sys.filegroups WHERE name != 'PRIMARY'" `
    -Username $Username -Password $Password -TrustServerCertificate

Write-Host "  Source database has $($sourceFGCount.cnt) FileGroups (besides PRIMARY)" -ForegroundColor Gray
Write-TestResult 'Source has FileGroups to test' ($sourceFGCount.cnt -gt 0)

if ($sourceFGCount.cnt -eq 0) {
    Write-Host '[ERROR] Source database has no FileGroups - cannot test FileGroup import' -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Export with minimal config
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 1: Export database with minimal config...' -ForegroundColor Cyan

# Clean up previous test exports
if (Test-Path $exportPath) {
    Remove-Item $exportPath -Recurse -Force
}

try {
    $null = & $exportScript `
        -Server $Server `
        -Database $Database `
        -OutputPath $exportPath `
        -Credential $credential `
        -ConfigFile $minimalConfigPath 2>&1

    $exportSuccess = $LASTEXITCODE -eq 0
    $exportDir = Get-ChildItem $exportPath -Directory | Select-Object -First 1

    Write-TestResult 'Export completed successfully' $exportSuccess

    if ($exportDir) {
        # Check FileGroups were exported
        $fgFolder = Join-Path $exportDir.FullName '00_FileGroups'
        $hasFGFolder = Test-Path $fgFolder
        Write-TestResult 'FileGroups folder exported' $hasFGFolder

        if ($hasFGFolder) {
            $fgFiles = Get-ChildItem $fgFolder -Filter '*.sql'
            Write-Host "  Found $($fgFiles.Count) FileGroup script(s)" -ForegroundColor Gray
        }
    }
}
catch {
    Write-TestResult 'Export completed successfully' $false $_.Exception.Message
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Import with minimal config - verify autoRemap default behavior
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 2: Import with minimal config (autoRemap default)...' -ForegroundColor Cyan

Drop-TestDatabase $targetDatabaseAutoRemap

try {
    $null = & $importScript `
        -Server $Server `
        -Database $targetDatabaseAutoRemap `
        -SourcePath $exportDir.FullName `
        -Credential $credential `
        -ConfigFile $minimalConfigPath `
        -CreateDatabase 2>&1

    $importSuccess = $LASTEXITCODE -eq 0
    Write-TestResult 'Import (autoRemap) completed' $importSuccess

    if ($importSuccess) {
        $fgCount = Get-FileGroupCount $targetDatabaseAutoRemap
        Write-Host "  Database has $fgCount FileGroups (besides PRIMARY)" -ForegroundColor Gray
        # Dev mode with autoRemap (default) DOES import FileGroups with auto-detected paths
        Write-TestResult 'Default autoRemap: FileGroups imported' ($fgCount -eq $sourceFGCount.cnt)
    }
}
catch {
    Write-TestResult 'Import (autoRemap) completed' $false $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Import WITH explicit fileGroupStrategy: autoRemap
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Test 3: Import with explicit fileGroupStrategy: autoRemap...' -ForegroundColor Cyan

Drop-TestDatabase $targetDatabaseExplicitFG

try {
    $null = & $importScript `
        -Server $Server `
        -Database $targetDatabaseExplicitFG `
        -SourcePath $exportDir.FullName `
        -Credential $credential `
        -ConfigFile $fileGroupsConfigPath `
        -CreateDatabase 2>&1

    $importSuccess = $LASTEXITCODE -eq 0
    Write-TestResult 'Import (explicit FG) completed' $importSuccess

    if ($importSuccess) {
        $fgCount = Get-FileGroupCount $targetDatabaseExplicitFG
        Write-Host "  Database has $fgCount FileGroups (besides PRIMARY)" -ForegroundColor Gray
        Write-TestResult 'FileGroups imported' ($fgCount -gt 0)
        Write-TestResult 'FileGroup count matches source' ($fgCount -eq $sourceFGCount.cnt)

        # Check file sizes are using the configured defaults (1 MB)
        $fileSizes = Invoke-Sqlcmd -ServerInstance $Server -Database $targetDatabaseExplicitFG `
            -Query "SELECT df.name, df.size * 8 / 1024 AS size_mb FROM sys.database_files df JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id WHERE fg.name != 'PRIMARY'" `
            -Username $Username -Password $Password -TrustServerCertificate

        if ($fileSizes) {
            $allSmall = $true
            foreach ($file in $fileSizes) {
                Write-Host "    File: $($file.name), Size: $($file.size_mb) MB" -ForegroundColor Gray
                if ($file.size_mb -gt 10) { $allSmall = $false }  # Should be ~1 MB, allow some margin
            }
            Write-TestResult 'FileGroup files use small defaults' $allSmall
        }
    }
}
catch {
    Write-TestResult 'Import (explicit FG) completed' $false $_.Exception.Message
}

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────
Write-Host ''
Write-Host '[INFO] Cleaning up...' -ForegroundColor Cyan

try {
    Drop-TestDatabase $targetDatabaseAutoRemap
    Write-Host "  Dropped $targetDatabaseAutoRemap" -ForegroundColor Gray

    Drop-TestDatabase $targetDatabaseExplicitFG
    Write-Host "  Dropped $targetDatabaseExplicitFG" -ForegroundColor Gray

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
    Write-Host '[SUCCESS] ALL FILEGROUP TESTS PASSED!' -ForegroundColor Green
    Write-Host 'fileGroupStrategy: autoRemap correctly imports FileGroups in Dev mode.' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[FAILED] $testsFailed test(s) failed" -ForegroundColor Red
    exit 1
}
