#Requires -Version 7.0

<#
.SYNOPSIS
    Tests environment variable credential injection for Export and Import scripts.

.DESCRIPTION
    This test validates that credential injection via environment variables works correctly:
    1. *FromEnv parameters resolve credentials from environment variables
    2. Config file connection: section resolves credentials from environment variables
    3. -TrustServerCertificate switch works correctly
    4. Precedence order is respected (CLI > *FromEnv > config > defaults)
    5. Passwords are never leaked to verbose output or logs
    6. Error handling for missing/empty environment variables
    7. Integration test: export and import using env var credentials

.NOTES
    Requires: SQL Server container running (docker-compose up -d)
    Tests Issue #58: Credential injection using environment variables
#>

param(
    [string]$ConfigFile = ".env"
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

# Load configuration from .env file
if (Test-Path (Join-Path $scriptDir $ConfigFile)) {
    Write-Host "Loading configuration from $ConfigFile..." -ForegroundColor Cyan
    Get-Content (Join-Path $scriptDir $ConfigFile) | ForEach-Object {
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
$ExportPath = Join-Path $scriptDir "exports_env_test"
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Script paths
$exportScript = Join-Path $projectRoot "Export-SqlServerSchema.ps1"
$importScript = Join-Path $projectRoot "Import-SqlServerSchema.ps1"

# Test results tracking
$script:testsPassed = 0
$script:testsFailed = 0

Write-Host "`n" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "ENVIRONMENT VARIABLE CREDENTIAL INJECTION TESTS" -ForegroundColor Cyan
Write-Host "Testing Issue #58: Credential injection using environment variables" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

# ==============================================================
# HELPER FUNCTIONS
# ==============================================================

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

# ==============================================================
# EXPORT SCRIPT TESTS
# ==============================================================

Write-Host "[INFO] Export Script Tests" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# --- Test 1: UsernameFromEnv and PasswordFromEnv resolve correctly ---
Write-Host "`n[INFO] Test 1: *FromEnv parameters resolve credentials from env vars" -ForegroundColor Cyan

$envUserVar = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envUserVar, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar, $Password, [System.EnvironmentVariableTarget]::Process)

try {
    # Export using env var credentials
    $testExportPath = Join-Path $ExportPath "env_test1"
    if (Test-Path $testExportPath) { Remove-Item $testExportPath -Recurse -Force }

    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -UsernameFromEnv $envUserVar -PasswordFromEnv $envPassVar `
        -TrustServerCertificate -OutputPath $testExportPath 2>&1

    $exportedDir = Get-ChildItem $testExportPath -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    $exportSuccess = $null -ne $exportedDir

    Write-TestResult "Export with *FromEnv credentials" $exportSuccess
} catch {
    Write-TestResult "Export with *FromEnv credentials" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 2: Missing UsernameFromEnv throws error ---
Write-Host "`n[INFO] Test 2: Missing username env var produces clear error" -ForegroundColor Cyan

$envPassVar2 = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envPassVar2, $Password, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -PasswordFromEnv $envPassVar2 `
        -TrustServerCertificate -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'UsernameFromEnv.*missing' -or $errorOutput -match 'Both are required'
    Write-TestResult "Missing UsernameFromEnv produces error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'UsernameFromEnv.*missing' -or $_.Exception.Message -match 'Both are required'
    Write-TestResult "Missing UsernameFromEnv produces error" $hasError
} finally {
    [System.Environment]::SetEnvironmentVariable($envPassVar2, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 3: Missing PasswordFromEnv throws error ---
Write-Host "`n[INFO] Test 3: Missing password env var produces clear error" -ForegroundColor Cyan

$envUserVar3 = "TEST_SQLCMD_USER_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envUserVar3, $Username, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -UsernameFromEnv $envUserVar3 `
        -TrustServerCertificate -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'PasswordFromEnv.*missing' -or $errorOutput -match 'Both are required'
    Write-TestResult "Missing PasswordFromEnv produces error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'PasswordFromEnv.*missing' -or $_.Exception.Message -match 'Both are required'
    Write-TestResult "Missing PasswordFromEnv produces error" $hasError
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar3, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 4: Empty/unset env var produces clear error ---
Write-Host "`n[INFO] Test 4: Unset environment variable produces clear error" -ForegroundColor Cyan

$envUserVar4 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar4 = "TEST_SQLCMD_PASS_$(Get-Random)"
# Only set username, leave password env var unset
[System.Environment]::SetEnvironmentVariable($envUserVar4, $Username, [System.EnvironmentVariableTarget]::Process)
# Ensure password var is NOT set
[System.Environment]::SetEnvironmentVariable($envPassVar4, $null, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -UsernameFromEnv $envUserVar4 -PasswordFromEnv $envPassVar4 `
        -TrustServerCertificate -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'not set'
    Write-TestResult "Unset password env var produces error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'not set'
    Write-TestResult "Unset password env var produces error" $hasError
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar4, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 5: CLI -Credential takes precedence over *FromEnv ---
Write-Host "`n[INFO] Test 5: CLI -Credential takes precedence over *FromEnv" -ForegroundColor Cyan

$envUserVar5 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar5 = "TEST_SQLCMD_PASS_$(Get-Random)"
# Set env vars to WRONG values
[System.Environment]::SetEnvironmentVariable($envUserVar5, "wrong_user", [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar5, "wrong_password", [System.EnvironmentVariableTarget]::Process)

try {
    # Pass correct credential via -Credential AND wrong *FromEnv - should succeed
    $testExportPath5 = Join-Path $ExportPath "env_test5"
    if (Test-Path $testExportPath5) { Remove-Item $testExportPath5 -Recurse -Force }

    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -Credential $credential `
        -UsernameFromEnv $envUserVar5 -PasswordFromEnv $envPassVar5 `
        -TrustServerCertificate -OutputPath $testExportPath5 2>&1

    $exportedDir = Get-ChildItem $testExportPath5 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "CLI -Credential takes precedence over *FromEnv" ($null -ne $exportedDir)
} catch {
    Write-TestResult "CLI -Credential takes precedence over *FromEnv" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar5, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar5, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 6: TrustServerCertificate switch works ---
Write-Host "`n[INFO] Test 6: -TrustServerCertificate switch works" -ForegroundColor Cyan

try {
    $testExportPath6 = Join-Path $ExportPath "env_test6"
    if (Test-Path $testExportPath6) { Remove-Item $testExportPath6 -Recurse -Force }

    # Export with -TrustServerCertificate switch (no config file needed)
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -Credential $credential -TrustServerCertificate `
        -OutputPath $testExportPath6 2>&1

    $exportedDir = Get-ChildItem $testExportPath6 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "TrustServerCertificate switch enables connection" ($null -ne $exportedDir)
} catch {
    Write-TestResult "TrustServerCertificate switch enables connection" $false "Error: $_"
}

# --- Test 7: Config file connection section works ---
Write-Host "`n[INFO] Test 7: Config file connection: section resolves credentials" -ForegroundColor Cyan

$envUserVar7 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar7 = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envUserVar7, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar7, $Password, [System.EnvironmentVariableTarget]::Process)

$configContent7 = @"
connection:
  usernameFromEnv: $envUserVar7
  passwordFromEnv: $envPassVar7
  trustServerCertificate: true
"@
$configPath7 = Join-Path $ExportPath "test-env-config.yml"
if (-not (Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null }
$configContent7 | Set-Content -Path $configPath7

try {
    $testExportPath7 = Join-Path $ExportPath "env_test7"
    if (Test-Path $testExportPath7) { Remove-Item $testExportPath7 -Recurse -Force }

    # Export using config file connection section (no -Credential or *FromEnv on CLI)
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -ConfigFile $configPath7 -OutputPath $testExportPath7 2>&1

    $exportedDir = Get-ChildItem $testExportPath7 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Config connection: section resolves credentials" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Config connection: section resolves credentials" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar7, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar7, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 8: Password not in verbose output ---
Write-Host "`n[INFO] Test 8: Password not leaked in verbose output" -ForegroundColor Cyan

$envUserVar8 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar8 = "TEST_SQLCMD_PASS_$(Get-Random)"
$testPassword8 = "S3cretP@ss_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envUserVar8, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar8, $testPassword8, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath8 = Join-Path $ExportPath "env_test8"
    if (Test-Path $testExportPath8) { Remove-Item $testExportPath8 -Recurse -Force }

    # Run with -Verbose to capture verbose output - use wrong password so it fails,
    # but we capture all output to check for password leakage
    $output = & $exportScript -Server $Server -Database $SourceDatabase `
        -UsernameFromEnv $envUserVar8 -PasswordFromEnv $envPassVar8 `
        -TrustServerCertificate -OutputPath $testExportPath8 -Verbose 2>&1

    $allOutput = $output | Out-String
    $passwordFound = $allOutput -match [regex]::Escape($testPassword8)
    Write-TestResult "Password not leaked in verbose output" (-not $passwordFound)
    if ($passwordFound) {
        Write-Host "  WARNING: Password found in output!" -ForegroundColor Red
    }
} catch {
    # Even if the export fails (wrong password), check the error output
    $allOutput = $_.Exception.Message
    $passwordFound = $allOutput -match [regex]::Escape($testPassword8)
    Write-TestResult "Password not leaked in verbose output" (-not $passwordFound)
} finally {
    [System.Environment]::SetEnvironmentVariable($envUserVar8, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar8, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 9: ServerFromEnv resolves server address ---
Write-Host "`n[INFO] Test 9: ServerFromEnv resolves server address" -ForegroundColor Cyan

$envServerVar9 = "TEST_SQLCMD_SERVER_$(Get-Random)"
$envUserVar9 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar9 = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envServerVar9, $Server, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envUserVar9, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar9, $Password, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath9 = Join-Path $ExportPath "env_test9"
    if (Test-Path $testExportPath9) { Remove-Item $testExportPath9 -Recurse -Force }

    # Export with ServerFromEnv
    $configContent9 = @"
connection:
  serverFromEnv: $envServerVar9
  usernameFromEnv: $envUserVar9
  passwordFromEnv: $envPassVar9
  trustServerCertificate: true
"@
    $configPath9 = Join-Path $ExportPath "test-env-server-config.yml"
    $configContent9 | Set-Content -Path $configPath9

    # Note: Server is still mandatory, but we pass a dummy value since
    # ServerFromEnv only takes effect when Server is not explicitly bound.
    # However, -Server is Mandatory, so we need to use the config approach.
    # Actually, when -Server IS provided, ServerFromEnv should be ignored.
    # Let's test that CLI -ServerFromEnv works by passing the env var name directly.
    $output = & $exportScript -Server "this-server-should-be-ignored" -Database $SourceDatabase `
        -ServerFromEnv $envServerVar9 `
        -UsernameFromEnv $envUserVar9 -PasswordFromEnv $envPassVar9 `
        -TrustServerCertificate -OutputPath $testExportPath9 2>&1

    # Since -Server is explicitly bound, ServerFromEnv should be ignored and connection will fail
    # because "this-server-should-be-ignored" is not a real server.
    # Actually, per our precedence: CLI -Server > -ServerFromEnv. Since Server IS bound, ServerFromEnv is ignored.
    # This means the export should FAIL with a connection error.
    $errorOutput = $output | Out-String
    $connectionFailed = $errorOutput -match 'Connection failed|could not|error|timeout'

    Write-TestResult "CLI -Server takes precedence over -ServerFromEnv" $connectionFailed
} catch {
    Write-TestResult "CLI -Server takes precedence over -ServerFromEnv" $true
} finally {
    [System.Environment]::SetEnvironmentVariable($envServerVar9, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envUserVar9, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar9, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 9b: ServerFromEnv works without -Server (Server is now optional) ---
Write-Host "`n[INFO] Test 9b: Export with ServerFromEnv and no -Server parameter" -ForegroundColor Cyan

$envServerVar9b = "TEST_SQLCMD_SERVER_$(Get-Random)"
$envUserVar9b = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar9b = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envServerVar9b, $Server, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envUserVar9b, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar9b, $Password, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath9b = Join-Path $ExportPath "env_test9b"
    if (Test-Path $testExportPath9b) { Remove-Item $testExportPath9b -Recurse -Force }

    # Export with NO -Server, relying entirely on ServerFromEnv
    $output = & $exportScript -Database $SourceDatabase `
        -ServerFromEnv $envServerVar9b `
        -UsernameFromEnv $envUserVar9b -PasswordFromEnv $envPassVar9b `
        -TrustServerCertificate -OutputPath $testExportPath9b 2>&1

    $exportedDir = Get-ChildItem $testExportPath9b -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Export with ServerFromEnv (no -Server)" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Export with ServerFromEnv (no -Server)" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($envServerVar9b, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envUserVar9b, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar9b, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 9c: Missing Server from all sources produces clear error ---
Write-Host "`n[INFO] Test 9c: Missing Server from all sources produces error" -ForegroundColor Cyan

try {
    # No -Server, no -ServerFromEnv, no config — should fail with clear error
    $output = & $exportScript -Database $SourceDatabase `
        -Credential $credential `
        -TrustServerCertificate -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'Server is required'
    Write-TestResult "Missing Server produces clear error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'Server is required'
    Write-TestResult "Missing Server produces clear error" $hasError
}

# --- Test 9d: Config serverFromEnv works without -Server ---
Write-Host "`n[INFO] Test 9d: Config serverFromEnv works without -Server" -ForegroundColor Cyan

$envServerVar9d = "TEST_SQLCMD_SERVER_$(Get-Random)"
$envUserVar9d = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar9d = "TEST_SQLCMD_PASS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envServerVar9d, $Server, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envUserVar9d, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar9d, $Password, [System.EnvironmentVariableTarget]::Process)

$configContent9d = @"
connection:
  serverFromEnv: $envServerVar9d
  usernameFromEnv: $envUserVar9d
  passwordFromEnv: $envPassVar9d
  trustServerCertificate: true
"@
$configPath9d = Join-Path $ExportPath "test-env-server-only-config.yml"
if (-not (Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null }
$configContent9d | Set-Content -Path $configPath9d

try {
    $testExportPath9d = Join-Path $ExportPath "env_test9d"
    if (Test-Path $testExportPath9d) { Remove-Item $testExportPath9d -Recurse -Force }

    # Export with NO -Server, relying entirely on config connection.serverFromEnv
    $output = & $exportScript -Database $SourceDatabase `
        -ConfigFile $configPath9d -OutputPath $testExportPath9d 2>&1

    $exportedDir = Get-ChildItem $testExportPath9d -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Config serverFromEnv works (no -Server)" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Config serverFromEnv works (no -Server)" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($envServerVar9d, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envUserVar9d, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar9d, $null, [System.EnvironmentVariableTarget]::Process)
}

# ==============================================================
# IMPORT SCRIPT TESTS
# ==============================================================

Write-Host "`n[INFO] Import Script Tests" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# First, create an export we can use for import testing
Write-Host "[INFO] Setup: Creating test export for import tests..." -ForegroundColor Gray

$importTestExportPath = Join-Path $ExportPath "import_source"
if (Test-Path $importTestExportPath) { Remove-Item $importTestExportPath -Recurse -Force }

& $exportScript -Server $Server -Database $SourceDatabase `
    -Credential $credential -TrustServerCertificate `
    -OutputPath $importTestExportPath 2>&1 | Out-Null

$importSourceDir = Get-ChildItem $importTestExportPath -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $importSourceDir) {
    Write-Host "[ERROR] Could not create test export for import tests. Skipping import tests." -ForegroundColor Red
} else {

    # --- Test 10: Import with *FromEnv credentials ---
    Write-Host "`n[INFO] Test 10: Import with *FromEnv credentials" -ForegroundColor Cyan

    $targetDb10 = "TestDb_EnvTest10"
    Drop-TestDatabase -DbName $targetDb10

    $envUserVar10 = "TEST_SQLCMD_USER_$(Get-Random)"
    $envPassVar10 = "TEST_SQLCMD_PASS_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envUserVar10, $Username, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar10, $Password, [System.EnvironmentVariableTarget]::Process)

    try {
        $output = & $importScript -Server $Server -Database $targetDb10 `
            -SourcePath $importSourceDir.FullName `
            -UsernameFromEnv $envUserVar10 -PasswordFromEnv $envPassVar10 `
            -TrustServerCertificate -CreateDatabase -Force 2>&1

        $outputStr = $output | Out-String
        $importSuccess = $outputStr -match 'Import completed|SUCCESS'
        Write-TestResult "Import with *FromEnv credentials" $importSuccess
    } catch {
        Write-TestResult "Import with *FromEnv credentials" $false "Error: $_"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envUserVar10, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envPassVar10, $null, [System.EnvironmentVariableTarget]::Process)
        Drop-TestDatabase -DbName $targetDb10
    }

    # --- Test 11: Import with config file connection section ---
    Write-Host "`n[INFO] Test 11: Import with config file connection: section" -ForegroundColor Cyan

    $targetDb11 = "TestDb_EnvTest11"
    Drop-TestDatabase -DbName $targetDb11

    $envUserVar11 = "TEST_SQLCMD_USER_$(Get-Random)"
    $envPassVar11 = "TEST_SQLCMD_PASS_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envUserVar11, $Username, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar11, $Password, [System.EnvironmentVariableTarget]::Process)

    $configContent11 = @"
connection:
  usernameFromEnv: $envUserVar11
  passwordFromEnv: $envPassVar11
  trustServerCertificate: true
import:
  defaultMode: Dev
"@
    $configPath11 = Join-Path $ExportPath "test-import-env-config.yml"
    $configContent11 | Set-Content -Path $configPath11

    try {
        $output = & $importScript -Server $Server -Database $targetDb11 `
            -SourcePath $importSourceDir.FullName `
            -ConfigFile $configPath11 -CreateDatabase -Force 2>&1

        $outputStr = $output | Out-String
        $importSuccess = $outputStr -match 'Import completed|SUCCESS'
        Write-TestResult "Import with config connection: section" $importSuccess
    } catch {
        Write-TestResult "Import with config connection: section" $false "Error: $_"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envUserVar11, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envPassVar11, $null, [System.EnvironmentVariableTarget]::Process)
        Drop-TestDatabase -DbName $targetDb11
    }

    # --- Test 12: Import - password not in error log ---
    Write-Host "`n[INFO] Test 12: Password not in import error log" -ForegroundColor Cyan

    $targetDb12 = "TestDb_EnvTest12"
    Drop-TestDatabase -DbName $targetDb12

    $envUserVar12 = "TEST_SQLCMD_USER_$(Get-Random)"
    $envPassVar12 = "TEST_SQLCMD_PASS_$(Get-Random)"
    $testPassword12 = "UniqueP@ss_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envUserVar12, $Username, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar12, $testPassword12, [System.EnvironmentVariableTarget]::Process)

    try {
        # This will likely fail due to wrong password, but we check that password isn't in output
        $output = & $importScript -Server $Server -Database $targetDb12 `
            -SourcePath $importSourceDir.FullName `
            -UsernameFromEnv $envUserVar12 -PasswordFromEnv $envPassVar12 `
            -TrustServerCertificate -CreateDatabase -Force -Verbose 2>&1

        $allOutput = $output | Out-String
        $passwordFound = $allOutput -match [regex]::Escape($testPassword12)
        Write-TestResult "Password not leaked in import output" (-not $passwordFound)
    } catch {
        $allOutput = $_.Exception.Message
        $passwordFound = $allOutput -match [regex]::Escape($testPassword12)
        Write-TestResult "Password not leaked in import output" (-not $passwordFound)
    } finally {
        [System.Environment]::SetEnvironmentVariable($envUserVar12, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envPassVar12, $null, [System.EnvironmentVariableTarget]::Process)
        Drop-TestDatabase -DbName $targetDb12
    }

    # --- Test 13: Import - TrustServerCertificate via config connection section ---
    Write-Host "`n[INFO] Test 13: Import TrustServerCertificate via config connection section" -ForegroundColor Cyan

    $targetDb13 = "TestDb_EnvTest13"
    Drop-TestDatabase -DbName $targetDb13

    $configContent13 = @"
connection:
  trustServerCertificate: true
import:
  defaultMode: Dev
"@
    $configPath13 = Join-Path $ExportPath "test-import-trust-config.yml"
    $configContent13 | Set-Content -Path $configPath13

    try {
        $output = & $importScript -Server $Server -Database $targetDb13 `
            -SourcePath $importSourceDir.FullName `
            -Credential $credential `
            -ConfigFile $configPath13 -CreateDatabase -Force 2>&1

        $outputStr = $output | Out-String
        $importSuccess = $outputStr -match 'Import completed|SUCCESS'
        Write-TestResult "TrustServerCertificate via config connection section" $importSuccess
    } catch {
        Write-TestResult "TrustServerCertificate via config connection section" $false "Error: $_"
    } finally {
        Drop-TestDatabase -DbName $targetDb13
    }

    # --- Test 13b: connection.trustServerCertificate false cannot be overridden by root-level true ---
    Write-Host "`n[INFO] Test 13b: connection.trustServerCertificate(false) not overridden by root-level(true)" -ForegroundColor Cyan

    $targetDb13b = "TestDb_EnvTest13b"
    Drop-TestDatabase -DbName $targetDb13b

    $configContent13b = @"
trustServerCertificate: true
connection:
  trustServerCertificate: false
import:
  defaultMode: Dev
"@
    $configPath13b = Join-Path $ExportPath "test-import-trust-override-config.yml"
    $configContent13b | Set-Content -Path $configPath13b

    try {
        # connection.trustServerCertificate: false should win over root-level true,
        # so the connection should fail (SQL Server container uses self-signed cert)
        $output = & $importScript -Server $Server -Database $targetDb13b `
            -SourcePath $importSourceDir.FullName `
            -Credential $credential `
            -ConfigFile $configPath13b -CreateDatabase -Force 2>&1

        $outputStr = $output | Out-String
        $connectionFailed = $outputStr -match 'certificate|trust|SSL|TLS|connection failed|error'
        Write-TestResult "connection.trustServerCertificate(false) not overridden by root-level(true)" $connectionFailed
    } catch {
        # A connection failure exception is the expected outcome
        Write-TestResult "connection.trustServerCertificate(false) not overridden by root-level(true)" $true
    } finally {
        Drop-TestDatabase -DbName $targetDb13b
    }

    # --- Test 14: Import - CLI *FromEnv takes precedence over config connection section ---
    Write-Host "`n[INFO] Test 14: CLI *FromEnv takes precedence over config connection section" -ForegroundColor Cyan

    $targetDb14 = "TestDb_EnvTest14"
    Drop-TestDatabase -DbName $targetDb14

    # Config file has wrong env var names
    $envUserVar14 = "TEST_SQLCMD_USER_$(Get-Random)"
    $envPassVar14 = "TEST_SQLCMD_PASS_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envUserVar14, $Username, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar14, $Password, [System.EnvironmentVariableTarget]::Process)

    # Config has WRONG env var references (these vars don't exist)
    $configContent14 = @"
connection:
  usernameFromEnv: NONEXISTENT_USER_VAR
  passwordFromEnv: NONEXISTENT_PASS_VAR
  trustServerCertificate: true
import:
  defaultMode: Dev
"@
    $configPath14 = Join-Path $ExportPath "test-import-precedence-config.yml"
    $configContent14 | Set-Content -Path $configPath14

    try {
        # CLI *FromEnv should override config connection section
        $output = & $importScript -Server $Server -Database $targetDb14 `
            -SourcePath $importSourceDir.FullName `
            -UsernameFromEnv $envUserVar14 -PasswordFromEnv $envPassVar14 `
            -ConfigFile $configPath14 -CreateDatabase -Force 2>&1

        $outputStr = $output | Out-String
        $importSuccess = $outputStr -match 'Import completed|SUCCESS'
        Write-TestResult "CLI *FromEnv takes precedence over config connection section" $importSuccess
    } catch {
        Write-TestResult "CLI *FromEnv takes precedence over config connection section" $false "Error: $_"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envUserVar14, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envPassVar14, $null, [System.EnvironmentVariableTarget]::Process)
        Drop-TestDatabase -DbName $targetDb14
    }
}

# ==============================================================
# RESULTS SUMMARY
# ==============================================================

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Passed: $($script:testsPassed)" -ForegroundColor Green
Write-Host "Failed: $($script:testsFailed)" -ForegroundColor $(if ($script:testsFailed -gt 0) { "Red" } else { "Green" })
Write-Host "Total:  $($script:testsPassed + $script:testsFailed)" -ForegroundColor Cyan
Write-Host "================================================================`n" -ForegroundColor Cyan

# Clean up
Write-Host "[INFO] Cleaning up test artifacts..." -ForegroundColor Gray
# Leave exports for inspection if tests fail
if ($script:testsFailed -eq 0 -and (Test-Path $ExportPath)) {
    Remove-Item $ExportPath -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:testsFailed -gt 0) {
    Write-Host "[FAILED] Some tests failed. See details above." -ForegroundColor Red
    exit 1
}

Write-Host "[SUCCESS] All tests passed!" -ForegroundColor Green
exit 0
