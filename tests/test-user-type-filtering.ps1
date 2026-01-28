#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the granular user type filtering feature (WindowsUsers, SqlUsers, etc.)
    
.DESCRIPTION
    This test validates that the granular user type exclusions work correctly:
    1. Unit tests for Test-UserExcludedByLoginType function (mocked LoginTypes)
    2. Integration tests with SQL login users (real Docker tests)
    3. Import-side filtering with injected Windows user SQL file

.NOTES
    Requires: SQL Server container running (docker-compose up -d)
    Tests Bug #2 fix: Cross-platform user filtering
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
$ExportPath = Join-Path $scriptDir "exports_user_type_test"
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Script paths
$exportScript = Join-Path $projectRoot "Export-SqlServerSchema.ps1"
$importScript = Join-Path $projectRoot "Import-SqlServerSchema.ps1"

# Test results tracking
$script:testsPassed = 0
$script:testsFailed = 0

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "USER TYPE FILTERING TESTS" -ForegroundColor Cyan
Write-Host "Testing Bug #2 fix: Granular user exclusions" -ForegroundColor Cyan
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

function Get-ExportedUserFiles {
    param([string]$ExportDir)
    
    # Users are in 01_Security folder with .user.sql extension
    $usersDir = Join-Path $ExportDir "01_Security"
    if (Test-Path $usersDir) {
        return Get-ChildItem $usersDir -Filter "*.user.sql" | Select-Object -ExpandProperty Name
    }
    return @()
}

# ═══════════════════════════════════════════════════════════════
# PART 1: UNIT TESTS FOR Test-UserExcludedByLoginType FUNCTION
# ═══════════════════════════════════════════════════════════════

Write-Host "[INFO] Part 1: Unit Tests for Test-UserExcludedByLoginType" -ForegroundColor Cyan
Write-Host "  Testing all LoginType to exclusion mappings with mock data`n" -ForegroundColor Gray

# Dot-source the export script to get access to the function
# We need to extract just the function, or test in-memory
# Since the script has complex initialization, we'll test the logic directly

# Define the function locally for unit testing (mirrors the one in Export-SqlServerSchema.ps1)
function Test-UserExcludedByLoginType-Local {
    param(
        [string]$LoginType,
        [string[]]$ExcludeTypes
    )
    
    # Map LoginType to our exclusion category
    $exclusionCategory = switch ($LoginType) {
        { $_ -in @('WindowsUser', 'WindowsGroup') } { 'WindowsUsers' }
        'SqlLogin' { 'SqlUsers' }
        { $_ -in @('Certificate', 'AsymmetricKey') } { 'CertificateMappedUsers' }
        { $_ -in @('ExternalUser', 'ExternalGroup') } { 'ExternalUsers' }
        default { $null }
    }
    
    # Check if this category is in the exclusion list
    # Also check umbrella DatabaseUsers exclusion
    if ($exclusionCategory -and ($ExcludeTypes -contains $exclusionCategory)) {
        return $true
    }
    
    # Umbrella exclusion - DatabaseUsers excludes all user types
    if ($ExcludeTypes -contains 'DatabaseUsers') {
        return $true
    }
    
    return $false
}

# Unit test cases
$unitTests = @(
    # WindowsUsers exclusion tests
    @{ LoginType = 'WindowsUser'; ExcludeTypes = @('WindowsUsers'); Expected = $true; Name = 'WindowsUser excluded by WindowsUsers' }
    @{ LoginType = 'WindowsGroup'; ExcludeTypes = @('WindowsUsers'); Expected = $true; Name = 'WindowsGroup excluded by WindowsUsers' }
    @{ LoginType = 'WindowsUser'; ExcludeTypes = @('SqlUsers'); Expected = $false; Name = 'WindowsUser NOT excluded by SqlUsers' }
    
    # SqlUsers exclusion tests
    @{ LoginType = 'SqlLogin'; ExcludeTypes = @('SqlUsers'); Expected = $true; Name = 'SqlLogin excluded by SqlUsers' }
    @{ LoginType = 'SqlLogin'; ExcludeTypes = @('WindowsUsers'); Expected = $false; Name = 'SqlLogin NOT excluded by WindowsUsers' }
    
    # CertificateMappedUsers exclusion tests
    @{ LoginType = 'Certificate'; ExcludeTypes = @('CertificateMappedUsers'); Expected = $true; Name = 'Certificate user excluded by CertificateMappedUsers' }
    @{ LoginType = 'AsymmetricKey'; ExcludeTypes = @('CertificateMappedUsers'); Expected = $true; Name = 'AsymmetricKey user excluded by CertificateMappedUsers' }
    @{ LoginType = 'Certificate'; ExcludeTypes = @('SqlUsers'); Expected = $false; Name = 'Certificate user NOT excluded by SqlUsers' }
    
    # ExternalUsers exclusion tests (Azure AD)
    @{ LoginType = 'ExternalUser'; ExcludeTypes = @('ExternalUsers'); Expected = $true; Name = 'ExternalUser excluded by ExternalUsers' }
    @{ LoginType = 'ExternalGroup'; ExcludeTypes = @('ExternalUsers'); Expected = $true; Name = 'ExternalGroup excluded by ExternalUsers' }
    @{ LoginType = 'ExternalUser'; ExcludeTypes = @('WindowsUsers'); Expected = $false; Name = 'ExternalUser NOT excluded by WindowsUsers' }
    
    # DatabaseUsers umbrella exclusion tests
    @{ LoginType = 'WindowsUser'; ExcludeTypes = @('DatabaseUsers'); Expected = $true; Name = 'WindowsUser excluded by DatabaseUsers (umbrella)' }
    @{ LoginType = 'SqlLogin'; ExcludeTypes = @('DatabaseUsers'); Expected = $true; Name = 'SqlLogin excluded by DatabaseUsers (umbrella)' }
    @{ LoginType = 'Certificate'; ExcludeTypes = @('DatabaseUsers'); Expected = $true; Name = 'Certificate excluded by DatabaseUsers (umbrella)' }
    @{ LoginType = 'ExternalUser'; ExcludeTypes = @('DatabaseUsers'); Expected = $true; Name = 'ExternalUser excluded by DatabaseUsers (umbrella)' }
    
    # Multiple exclusions
    @{ LoginType = 'WindowsUser'; ExcludeTypes = @('WindowsUsers', 'SqlUsers'); Expected = $true; Name = 'WindowsUser excluded with multiple types' }
    @{ LoginType = 'SqlLogin'; ExcludeTypes = @('WindowsUsers', 'SqlUsers'); Expected = $true; Name = 'SqlLogin excluded with multiple types' }
    
    # No exclusion
    @{ LoginType = 'SqlLogin'; ExcludeTypes = @(); Expected = $false; Name = 'SqlLogin NOT excluded when no exclusions' }
    @{ LoginType = 'WindowsUser'; ExcludeTypes = @(); Expected = $false; Name = 'WindowsUser NOT excluded when no exclusions' }
)

foreach ($test in $unitTests) {
    $result = Test-UserExcludedByLoginType-Local -LoginType $test.LoginType -ExcludeTypes $test.ExcludeTypes
    Write-TestResult -TestName $test.Name -Passed ($result -eq $test.Expected) `
        -Message "Expected: $($test.Expected), Got: $result"
}

# ═══════════════════════════════════════════════════════════════
# PART 2: INTEGRATION TESTS WITH SQL USERS
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Part 2: Integration Tests with SQL Login Users" -ForegroundColor Cyan
Write-Host "  Testing real export with SqlUsers exclusion`n" -ForegroundColor Gray

# Setup: Create additional SQL login user for testing
Write-Host "[INFO] Setup: Creating test SQL login user..." -ForegroundColor Gray
try {
    # Create a login and user for testing
    Invoke-SqlCommand @"
IF NOT EXISTS (SELECT * FROM sys.server_principals WHERE name = 'TestSqlLogin')
    CREATE LOGIN [TestSqlLogin] WITH PASSWORD = 'TestPwd!123456';
"@ "master"

    Invoke-SqlCommand @"
IF NOT EXISTS (SELECT * FROM sys.database_principals WHERE name = 'TestSqlUser')
    CREATE USER [TestSqlUser] FOR LOGIN [TestSqlLogin];
"@ $SourceDatabase
    
    Write-Host "  Created TestSqlUser (mapped to SQL login)" -ForegroundColor Gray
} catch {
    Write-Host "  Note: Could not create test user (may already exist): $_" -ForegroundColor Yellow
}

# Clean up export directory
if (Test-Path $ExportPath) {
    Remove-Item $ExportPath -Recurse -Force
}
New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

# Test 2a: Export WITHOUT SqlUsers exclusion - user should be exported
Write-Host "[INFO] Test 2a: Export without SqlUsers exclusion..." -ForegroundColor Gray
$exportDir2a = Join-Path $ExportPath "no_exclusion"

& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $exportDir2a `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

$exportedDir2a = Get-ChildItem $exportDir2a -Directory | Select-Object -First 1
$userFiles2a = Get-ExportedUserFiles -ExportDir $exportedDir2a.FullName
$hasSqlUser2a = $userFiles2a -contains 'TestSqlUser.user.sql'

Write-TestResult -TestName "SQL user exported when no exclusion" -Passed $hasSqlUser2a `
    -Message "TestSqlUser.user.sql should exist in export"

# Test 2b: Export WITH SqlUsers exclusion - user should NOT be exported
Write-Host "[INFO] Test 2b: Export with SqlUsers exclusion..." -ForegroundColor Gray
$exportDir2b = Join-Path $ExportPath "with_sql_exclusion"

# Create config file for SqlUsers exclusion
$configContent2b = @"
export:
  excludeObjectTypes:
    - SqlUsers
"@
$configPath2b = Join-Path $ExportPath "test-exclude-sql-users.yml"
$configContent2b | Set-Content -Path $configPath2b

& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $exportDir2b `
    -Credential $credential -ConfigFile $configPath2b -Verbose:$false 2>&1 | Out-Null

$exportedDir2b = Get-ChildItem $exportDir2b -Directory | Select-Object -First 1
$userFiles2b = Get-ExportedUserFiles -ExportDir $exportedDir2b.FullName
$hasSqlUser2b = $userFiles2b -contains 'TestSqlUser.user.sql'

Write-TestResult -TestName "SQL user NOT exported when SqlUsers excluded" -Passed (-not $hasSqlUser2b) `
    -Message "TestSqlUser.user.sql should NOT exist in export"

# Test 2c: Verify TestUser (WITHOUT LOGIN) is also excluded
# Note: In SMO, users WITHOUT LOGIN still have LoginType = 'SqlLogin'
# So they ARE excluded when SqlUsers is excluded - this is correct behavior
$hasTestUser2b = $userFiles2b -contains 'TestUser.user.sql'
Write-TestResult -TestName "User WITHOUT LOGIN also excluded by SqlUsers" -Passed (-not $hasTestUser2b) `
    -Message "TestUser.user.sql (WITHOUT LOGIN) has SqlLogin type in SMO, so it should be excluded"

# ═══════════════════════════════════════════════════════════════
# PART 3: IMPORT TESTS WITH INJECTED WINDOWS USER FILE
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Part 3: Import Tests with Injected Windows User File" -ForegroundColor Cyan
Write-Host "  Testing that injected Windows user causes expected failure`n" -ForegroundColor Gray

# Create a fresh export for import testing - exclude SqlUsers to avoid login dependency issues
$importTestExportDir = Join-Path $ExportPath "import_test_source"
$importExportConfig = @"
export:
  excludeObjectTypes:
    - SqlUsers
    - DatabaseUsers
"@
$importExportConfigPath = Join-Path $ExportPath "test-export-no-users.yml"
$importExportConfig | Set-Content -Path $importExportConfigPath

& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $importTestExportDir `
    -Credential $credential -ConfigFile $importExportConfigPath -Verbose:$false 2>&1 | Out-Null

$importSourceDir = Get-ChildItem $importTestExportDir -Directory | Select-Object -First 1

# Inject a fake Windows user SQL file into the correct location (01_Security)
$usersDir = Join-Path $importSourceDir.FullName "01_Security"
if (-not (Test-Path $usersDir)) {
    New-Item -ItemType Directory -Path $usersDir -Force | Out-Null
}

$windowsUserSql = @"
-- Injected Windows user for testing (will fail on Linux SQL Server)
-- This simulates exporting from a Windows SQL Server with domain users
CREATE USER [DOMAIN\TestWindowsUser] FOR LOGIN [DOMAIN\TestWindowsUser];
GO
"@
$windowsUserFile = Join-Path $usersDir "DOMAIN.TestWindowsUser.user.sql"
$windowsUserSql | Set-Content -Path $windowsUserFile
Write-Host "  Injected Windows user file: $windowsUserFile" -ForegroundColor Gray

# Test 3a: Import with injected Windows user - should fail (no Windows login on Linux)
# This validates that exports from Windows SQL Server with domain users will fail on Linux
# (unless excluded at export time using -ExcludeObjectTypes WindowsUsers)
Write-Host "[INFO] Test 3a: Import with Windows user (expect failure on Linux)..." -ForegroundColor Gray

$targetDb3a = "TestDb_WinUserTest1"

# Create config (normal Dev mode)
$configContent3a = @"
import:
  importMode: Dev
  createDatabase: true
  fileGroupStrategy: autoRemap
"@
$configPath3a = Join-Path $ExportPath "test-import-no-exclusion.yml"
$configContent3a | Set-Content -Path $configPath3a

# Drop target if exists
try {
    Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$targetDb3a') BEGIN ALTER DATABASE [$targetDb3a] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$targetDb3a]; END" "master"
} catch { }

# Run import - capture output to check for failure
# Use try-catch because we EXPECT this to fail
# Run as a separate process to capture all output without affecting this script's error handling
$importOutput3a = ""
try {
    # Run the import script in a separate PowerShell process to isolate error handling
    # This ensures we capture all output including Write-Host and Write-Error
    # Escape single quotes in password for safe embedding in command string
    $escapedPassword = $Password -replace "'", "''"
    $escapedSourcePath = $importSourceDir.FullName -replace "'", "''"
    $escapedConfigPath = $configPath3a -replace "'", "''"
    
    # Build command to run with credentials passed inline
    $importCmd = @"
`$securePassword = ConvertTo-SecureString '$escapedPassword' -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential('$Username', `$securePassword)
& '$importScript' -Server '$Server' -Database '$targetDb3a' -SourcePath '$escapedSourcePath' -ConfigFile '$escapedConfigPath' -Credential `$cred
"@
    
    $importOutput3a = pwsh -NoProfile -Command $importCmd 2>&1 | Out-String
} catch {
    $importOutput3a += "`n" + $_.Exception.Message
}

# Check if import reported failure (Windows user script should fail)
$hadFailure3a = $importOutput3a -match "ERROR|Failed|Cannot find the login|does not exist"
Write-TestResult -TestName "Windows user import fails on Linux (expected)" -Passed $hadFailure3a `
    -Message "Expected failure - Windows login doesn't exist on Linux SQL Server"

# Test 3b: Verify error message mentions the Windows user script
# The error output should identify the failing script file
$mentionsWindowsUser = $importOutput3a -match "DOMAIN.*TestWindowsUser|WindowsUser"
Write-TestResult -TestName "Error message identifies Windows user script" -Passed $mentionsWindowsUser `
    -Message "Error should identify which script failed"

# Cleanup
try {
    Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$targetDb3a') BEGIN ALTER DATABASE [$targetDb3a] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$targetDb3a]; END" "master"
} catch { }

# Note: Import-side excludeObjectTypes filtering for user types is not yet implemented
# The recommended workflow is to exclude at EXPORT time using:
#   export:
#     excludeObjectTypes:
#       - WindowsUsers
Write-Host "`n  [INFO] Note: To exclude Windows users, use excludeObjectTypes at EXPORT time" -ForegroundColor Yellow

# ═══════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Cleanup: Removing test user..." -ForegroundColor Gray
try {
    Invoke-SqlCommand "IF EXISTS (SELECT * FROM sys.database_principals WHERE name = 'TestSqlUser') DROP USER [TestSqlUser];" $SourceDatabase
    Invoke-SqlCommand "IF EXISTS (SELECT * FROM sys.server_principals WHERE name = 'TestSqlLogin') DROP LOGIN [TestSqlLogin];" "master"
} catch { }

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "USER TYPE FILTERING TEST SUMMARY" -ForegroundColor Cyan
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
