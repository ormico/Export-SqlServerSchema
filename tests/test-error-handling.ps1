#Requires -Version 7.0

<#
.SYNOPSIS
    Tests error handling and reporting improvements
    
.DESCRIPTION
    This test validates that error handling improvements work correctly:
    1. Errors are displayed in red with [ERROR] prefix
    2. Error log file is created when errors occur
    3. Final summary shows failure counts
    4. Script names and error details are in error messages

.NOTES
    Requires: SQL Server container running (docker-compose up -d)
    Tests Bug #3 fix: Improved error reporting
#>

param(
    [string]$ConfigFile = ".env"
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

# Load configuration from .env file
if (Test-Path $ConfigFile) {
    Write-Host "Loading configuration from $ConfigFile..." -ForegroundColor Cyan
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.+?)\s*$') {
            $name = $matches[1]
            $value = $matches[2]
            Set-Variable -Name $name -Value $value -Scope Script
        }
    }
} else {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

# Configuration
$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourceDatabase = $TEST_DATABASE
$ExportPath = Join-Path $scriptDir "exports_error_test"
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Script paths
$exportScript = Join-Path $projectRoot "Export-SqlServerSchema.ps1"
$importScript = Join-Path $projectRoot "Import-SqlServerSchema.ps1"

# Test results tracking
$script:testsPassed = 0
$script:testsFailed = 0

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "ERROR HANDLING TESTS" -ForegroundColor Cyan
Write-Host "Testing Bug #3 fix: Improved error reporting" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ''
    )
    if ($Passed) {
        Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    } else {
        Write-Host "[FAILED] $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )
    
    $result = sqlcmd -S $Server -U $Username -P $Password -d $Database -C -Q $Query -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL command failed: $result"
    }
    return $result
}

function Drop-TestDatabase {
    param([string]$DbName)
    try {
        Invoke-SqlCommand @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$DbName')
BEGIN
    ALTER DATABASE [$DbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DbName];
END
"@ "master"
    } catch { }
}

# ═══════════════════════════════════════════════════════════════
# SETUP
# ═══════════════════════════════════════════════════════════════

Write-Host "[INFO] Setup: Creating test export with intentional error..." -ForegroundColor Cyan

# Clean export directory
if (Test-Path $ExportPath) {
    Remove-Item $ExportPath -Recurse -Force
}
New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

# Create a clean export first
$exportDir = Join-Path $ExportPath "source_export"
& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $exportDir `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

$exportedDir = Get-ChildItem $exportDir -Directory | Select-Object -First 1

# Inject an intentionally broken SQL script
$brokenScriptDir = Join-Path $exportedDir.FullName "14_Programmability" "02_Functions"
if (-not (Test-Path $brokenScriptDir)) {
    New-Item -ItemType Directory -Path $brokenScriptDir -Force | Out-Null
}

$brokenSql = @"
-- Intentionally broken SQL for error testing
CREATE FUNCTION dbo.fn_BrokenFunction()
RETURNS INT
AS
BEGIN
    -- This will fail because we reference a non-existent table
    DECLARE @Result INT;
    SELECT @Result = COUNT(*) FROM dbo.NonExistentTable_XYZ123;
    RETURN @Result;
END;
GO
"@
$brokenScriptPath = Join-Path $brokenScriptDir "dbo.fn_BrokenFunction.sql"
$brokenSql | Set-Content -Path $brokenScriptPath
Write-Host "  Injected broken script: dbo.fn_BrokenFunction.sql" -ForegroundColor Gray

# ═══════════════════════════════════════════════════════════════
# TEST 1: ERROR REPORTING IN IMPORT OUTPUT
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 1: Error Reporting in Import Output" -ForegroundColor Cyan

$targetDb1 = "TestDb_ErrorTest1"
Drop-TestDatabase -DbName $targetDb1

$configContent1 = @"
import:
  importMode: Dev
  createDatabase: true
  fileGroupStrategy: autoRemap
"@
$configPath1 = Join-Path $ExportPath "test-error-handling.yml"
$configContent1 | Set-Content -Path $configPath1

# Capture all output including stderr
$importOutput = & $importScript -Server $Server -Database $targetDb1 `
    -SourcePath $exportedDir.FullName -ConfigFile $configPath1 `
    -Credential $credential 2>&1 | Out-String

# Test 1a: Check for error prefix in output
$hasErrorPrefix = $importOutput -match "\[ERROR\]"
Write-TestResult -TestName "Output contains [ERROR] prefix" -Passed $hasErrorPrefix `
    -Message "Error messages should have [ERROR] prefix"

# Test 1b: Check that broken script name is mentioned
$mentionsBrokenScript = $importOutput -match "fn_BrokenFunction|BrokenFunction"
Write-TestResult -TestName "Error mentions broken script name" -Passed $mentionsBrokenScript `
    -Message "Error should mention the failing script"

# Test 1c: Check that error details are present
$hasErrorDetails = $importOutput -match "NonExistentTable|Invalid object name"
Write-TestResult -TestName "Error includes SQL error details" -Passed $hasErrorDetails `
    -Message "Error should include SQL Server error message"

# Test 1d: Check for failure count in summary
$hasFailureCount = $importOutput -match "Failed|failure|error.*\d+"
Write-TestResult -TestName "Summary shows failure information" -Passed $hasFailureCount `
    -Message "Final summary should indicate failures occurred"

# ═══════════════════════════════════════════════════════════════
# TEST 2: ERROR LOG FILE CREATION
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 2: Error Log File Creation" -ForegroundColor Cyan

# Check if error log was created
$errorLogPattern = Join-Path $exportedDir.FullName "import_errors_*.log"
$errorLogs = Get-ChildItem -Path $exportedDir.FullName -Filter "import_errors_*.log" -ErrorAction SilentlyContinue

$hasErrorLog = $errorLogs.Count -gt 0
Write-TestResult -TestName "Error log file created" -Passed $hasErrorLog `
    -Message "An import_errors_*.log file should be created when errors occur"

if ($hasErrorLog) {
    $errorLogContent = Get-Content $errorLogs[0].FullName -Raw
    
    # Test 2a: Error log contains script name
    $logHasScript = $errorLogContent -match "fn_BrokenFunction"
    Write-TestResult -TestName "Error log contains script name" -Passed $logHasScript `
        -Message "Error log should list the failing script"
    
    # Test 2b: Error log contains error message
    $logHasError = $errorLogContent -match "NonExistentTable|Invalid object"
    Write-TestResult -TestName "Error log contains error details" -Passed $logHasError `
        -Message "Error log should contain SQL error message"
    
    # Test 2c: Error log has timestamp
    $logHasTimestamp = $errorLogContent -match "\d{4}-\d{2}-\d{2}|\d{2}:\d{2}:\d{2}"
    Write-TestResult -TestName "Error log has timestamp" -Passed $logHasTimestamp `
        -Message "Error log should include timestamps"
}

Drop-TestDatabase -DbName $targetDb1

# ═══════════════════════════════════════════════════════════════
# TEST 3: SUCCESSFUL IMPORT DOES NOT CREATE ERROR LOG
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 3: Successful Import Has No Error Log" -ForegroundColor Cyan

# Create a clean export without the broken script
$cleanExportDir = Join-Path $ExportPath "clean_export"
& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $cleanExportDir `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

$cleanExportedDir = Get-ChildItem $cleanExportDir -Directory | Select-Object -First 1

$targetDb3 = "TestDb_ErrorTest3"
Drop-TestDatabase -DbName $targetDb3

$cleanImportOutput = & $importScript -Server $Server -Database $targetDb3 `
    -SourcePath $cleanExportedDir.FullName -ConfigFile $configPath1 `
    -Credential $credential 2>&1 | Out-String

# Check that no error log was created
$cleanErrorLogs = Get-ChildItem -Path $cleanExportedDir.FullName -Filter "import_errors_*.log" -ErrorAction SilentlyContinue
$noErrorLog = $cleanErrorLogs.Count -eq 0

Write-TestResult -TestName "No error log for successful import" -Passed $noErrorLog `
    -Message "Error log should NOT be created when import succeeds"

# Check output shows success
$showsSuccess = $cleanImportOutput -match "Import completed successfully"
Write-TestResult -TestName "Successful import shows success message" -Passed $showsSuccess `
    -Message "Output should confirm successful completion"

Drop-TestDatabase -DbName $targetDb3

# ═══════════════════════════════════════════════════════════════
# TEST 4: DEPENDENCY RETRY ERRORS ARE TRACKED
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 4: Dependency Retry Final Failures Are Reported" -ForegroundColor Cyan

# Create export with function that has unresolvable dependency
$retryExportDir = Join-Path $ExportPath "retry_export"
& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $retryExportDir `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

$retryExportedDir = Get-ChildItem $retryExportDir -Directory | Select-Object -First 1

# Inject function with impossible dependency (references non-existent object)
$retryBrokenDir = Join-Path $retryExportedDir.FullName "14_Programmability" "02_Functions"
$retryBrokenSql = @"
-- Function with unresolvable dependency
CREATE FUNCTION dbo.fn_UnresolvableDep()
RETURNS TABLE
AS
RETURN (SELECT * FROM dbo.TableThatWillNeverExist_ABC);
GO
"@
$retryBrokenPath = Join-Path $retryBrokenDir "dbo.fn_UnresolvableDep.sql"
$retryBrokenSql | Set-Content -Path $retryBrokenPath

$targetDb4 = "TestDb_RetryError"
Drop-TestDatabase -DbName $targetDb4

$retryImportOutput = & $importScript -Server $Server -Database $targetDb4 `
    -SourcePath $retryExportedDir.FullName -ConfigFile $configPath1 `
    -Credential $credential 2>&1 | Out-String

# Check that retry failure is reported clearly
$reportsRetryFailure = $retryImportOutput -match "fn_UnresolvableDep.*failed|failed.*fn_UnresolvableDep|\[ERROR\].*fn_UnresolvableDep"
Write-TestResult -TestName "Retry failure clearly reported" -Passed $reportsRetryFailure `
    -Message "Scripts that fail after retry should be clearly reported"

Drop-TestDatabase -DbName $targetDb4

# ═══════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Cleanup..." -ForegroundColor Gray
# Keep export directories for debugging if tests fail

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "ERROR HANDLING TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

Write-Host "Tests Passed: $script:testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $script:testsFailed" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })

if ($script:testsFailed -gt 0) {
    Write-Host "`n[FAILED] Some tests failed!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[SUCCESS] All tests passed!" -ForegroundColor Green
    exit 0
}
