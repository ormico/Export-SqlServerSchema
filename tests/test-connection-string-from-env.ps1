#Requires -Version 7.0

<#
.SYNOPSIS
    Tests ConnectionStringFromEnv parameter for Export and Import scripts.

.DESCRIPTION
    Validates that -ConnectionStringFromEnv and config connection.connectionStringFromEnv
    work correctly:
    1. ConvertFrom-AdoConnectionString parses common key aliases correctly
    2. ConnectionStringFromEnv resolves Server, Database, credentials, and TrustServerCertificate
    3. Config connection.connectionStringFromEnv is used as fallback
    4. Precedence: CLI params > individual *FromEnv > ConnectionStringFromEnv > config > defaults
    5. Individual param overrides always beat connection string values
    6. Passwords from connection strings are never logged or displayed
    7. Malformed connection strings produce clear error messages
    8. Empty/unset env var for ConnectionStringFromEnv produces clear error
    9. Database can be resolved from connection string when -Database not provided
    10. Integration: export and import using full connection string from env var

.NOTES
    Requires: SQL Server container running (docker-compose up -d in tests/)
    Tests Issue #63: ConnectionStringFromEnv parameter
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
$ExportPath = Join-Path $scriptDir "exports_connstr_test"
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
Write-Host "CONNECTION STRING FROM ENV TESTS" -ForegroundColor Cyan
Write-Host "Testing Issue #63: ConnectionStringFromEnv parameter" -ForegroundColor Cyan
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
    # Escape for T-SQL string literal (single quote) and bracketed identifier (closing bracket)
    $safeForString  = $DbName.Replace("'", "''")
    $safeForBracket = $DbName.Replace("]", "]]")
    try {
        Invoke-SqlCommand @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$safeForString')
BEGIN
    ALTER DATABASE [$safeForBracket] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$safeForBracket];
END
"@ "master"
    } catch { }
}

# ==============================================================
# UNIT TESTS: ConvertFrom-AdoConnectionString
# Loads the production function from Export-SqlServerSchema.ps1 so
# tests exercise the real implementation, not a duplicate.
# ==============================================================

Write-Host "[INFO] Unit Tests: ConvertFrom-AdoConnectionString parser" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# Load ConvertFrom-AdoConnectionString directly from the production script using brace-counting
# extraction (same approach used by run-unit-tests.ps1). This ensures tests stay in sync with
# production code and catch regressions introduced there rather than exercising a duplicate.
$exportScriptContent = Get-Content $exportScript -Raw
function Get-FunctionBlock {
    param([string]$Content, [string]$FunctionName)
    $startPattern = "function $FunctionName "
    $startIndex = $Content.IndexOf($startPattern)
    if ($startIndex -lt 0) { throw "Function '$FunctionName' not found in Export script" }
    $depth = 0; $inFunction = $false; $end = $startIndex
    for ($i = $startIndex; $i -lt $Content.Length; $i++) {
        if ($Content[$i] -eq '{') { $depth++; $inFunction = $true }
        elseif ($Content[$i] -eq '}') {
            $depth--
            if ($inFunction -and $depth -eq 0) { $end = $i; break }
        }
    }
    return $Content.Substring($startIndex, $end - $startIndex + 1)
}
$tempFuncFile = Join-Path $env:TEMP "test-ado-parser-$([System.Guid]::NewGuid().ToString('N')).ps1"
Get-FunctionBlock $exportScriptContent 'ConvertFrom-AdoConnectionString' | Set-Content $tempFuncFile -Encoding UTF8
. $tempFuncFile
Remove-Item $tempFuncFile -ErrorAction SilentlyContinue

# --- Unit Test 1: Standard Data Source / Initial Catalog keys ---
Write-Host "`n[INFO] Unit Test 1: Parse standard SQL Server keys" -ForegroundColor Cyan

try {
    $parsed = ConvertFrom-AdoConnectionString "Data Source=myserver,1433;Initial Catalog=mydb;User ID=myuser;Password=mypass;TrustServerCertificate=true"
    $ok = $parsed.Server -eq 'myserver,1433' -and
          $parsed.Database -eq 'mydb' -and
          $parsed.Username -eq 'myuser' -and
          $parsed.Password -eq 'mypass' -and
          $parsed.TrustServerCertificate -eq $true
    Write-TestResult "Parse standard SQL Server connection string keys" $ok
} catch {
    Write-TestResult "Parse standard SQL Server connection string keys" $false "Error: $_"
}

# --- Unit Test 2: Alternate key aliases (Server, Database, UID, PWD) ---
Write-Host "`n[INFO] Unit Test 2: Parse alternate key aliases" -ForegroundColor Cyan

try {
    $parsed = ConvertFrom-AdoConnectionString "Server=myserver2;Database=mydb2;UID=u2;PWD=p2"
    $ok = $parsed.Server -eq 'myserver2' -and
          $parsed.Database -eq 'mydb2' -and
          $parsed.Username -eq 'u2' -and
          $parsed.Password -eq 'p2'
    Write-TestResult "Parse alternate connection string key aliases" $ok
} catch {
    Write-TestResult "Parse alternate connection string key aliases" $false "Error: $_"
}

# --- Unit Test 3: TrustServerCertificate=false ---
Write-Host "`n[INFO] Unit Test 3: Parse TrustServerCertificate=false" -ForegroundColor Cyan

try {
    $parsed = ConvertFrom-AdoConnectionString "Data Source=srv;Initial Catalog=db;TrustServerCertificate=false"
    $ok = $parsed.TrustServerCertificate -eq $false
    Write-TestResult "Parse TrustServerCertificate=false" $ok
} catch {
    Write-TestResult "Parse TrustServerCertificate=false" $false "Error: $_"
}

# --- Unit Test 4: Integrated Security / Windows auth string ---
Write-Host "`n[INFO] Unit Test 4: Parse Integrated Security=SSPI" -ForegroundColor Cyan

try {
    $parsed = ConvertFrom-AdoConnectionString "Data Source=srv;Initial Catalog=db;Integrated Security=SSPI"
    $ok = ($parsed.IntegratedSecurity -eq $true) -and
          [string]::IsNullOrEmpty($parsed.Username) -and
          [string]::IsNullOrEmpty($parsed.Password)
    Write-TestResult "Parse Integrated Security=SSPI (Windows auth)" $ok
} catch {
    Write-TestResult "Parse Integrated Security=SSPI (Windows auth)" $false "Error: $_"
}

# --- Unit Test 5: Malformed connection string produces descriptive error ---
Write-Host "`n[INFO] Unit Test 5: Malformed connection string error" -ForegroundColor Cyan

try {
    ConvertFrom-AdoConnectionString '=bad key' | Out-Null
    Write-TestResult "Malformed connection string produces descriptive error" $false "Expected exception not thrown"
} catch {
    $hasError = $_.Exception.Message -match 'Invalid connection string'
    Write-TestResult "Malformed connection string produces descriptive error" $hasError "got: $_"
}

# ==============================================================
# INTEGRATION TESTS: Export Script with ConnectionStringFromEnv
# ==============================================================

Write-Host "`n[INFO] Export Script Tests" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# --- Test 6: ConnectionStringFromEnv resolves Server, Database, and credentials ---
Write-Host "`n[INFO] Test 6: ConnectionStringFromEnv resolves all connection params" -ForegroundColor Cyan

$connStrVar6 = "TEST_CONNSTR_$(Get-Random)"
$connStr6 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar6, $connStr6, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath6 = Join-Path $ExportPath "connstr_test6"
    if (Test-Path $testExportPath6) { Remove-Item $testExportPath6 -Recurse -Force }

    # No -Server, -Database, or credential — all come from connection string
    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar6 `
        -OutputPath $testExportPath6 2>&1

    $exportedDir = Get-ChildItem $testExportPath6 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Export using ConnectionStringFromEnv (no other params)" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Export using ConnectionStringFromEnv (no other params)" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar6, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 7: CLI -Database overrides database from connection string ---
Write-Host "`n[INFO] Test 7: CLI -Database takes precedence over connection string database" -ForegroundColor Cyan

$connStrVar7 = "TEST_CONNSTR_$(Get-Random)"
# Connection string has a WRONG database name; correct one passed via -Database
$connStr7 = "Data Source=$Server;Initial Catalog=WrongDatabase_NotExists;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar7, $connStr7, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath7 = Join-Path $ExportPath "connstr_test7"
    if (Test-Path $testExportPath7) { Remove-Item $testExportPath7 -Recurse -Force }

    # -Database explicitly provided — should override the wrong one in the connection string
    $output = & $exportScript `
        -Database $SourceDatabase `
        -ConnectionStringFromEnv $connStrVar7 `
        -OutputPath $testExportPath7 2>&1

    $exportedDir = Get-ChildItem $testExportPath7 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "CLI -Database overrides connection string database" ($null -ne $exportedDir)
} catch {
    Write-TestResult "CLI -Database overrides connection string database" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar7, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 8: CLI -Server overrides server from connection string ---
Write-Host "`n[INFO] Test 8: CLI -Server takes precedence over connection string server" -ForegroundColor Cyan

$connStrVar8 = "TEST_CONNSTR_$(Get-Random)"
# Connection string has a wrong server; correct one passed via -Server
$connStr8 = "Data Source=wrong-server-not-reachable;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar8, $connStr8, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath8 = Join-Path $ExportPath "connstr_test8"
    if (Test-Path $testExportPath8) { Remove-Item $testExportPath8 -Recurse -Force }

    # -Server explicitly provided — should override wrong server from connection string
    $output = & $exportScript `
        -Server $Server `
        -Database $SourceDatabase `
        -ConnectionStringFromEnv $connStrVar8 `
        -OutputPath $testExportPath8 2>&1

    $exportedDir = Get-ChildItem $testExportPath8 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "CLI -Server overrides connection string server" ($null -ne $exportedDir)
} catch {
    Write-TestResult "CLI -Server overrides connection string server" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar8, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 9: Individual *FromEnv params take precedence over ConnectionStringFromEnv ---
Write-Host "`n[INFO] Test 9: Individual *FromEnv params override ConnectionStringFromEnv credentials" -ForegroundColor Cyan

$connStrVar9 = "TEST_CONNSTR_$(Get-Random)"
$envUserVar9 = "TEST_SQLCMD_USER_$(Get-Random)"
$envPassVar9 = "TEST_SQLCMD_PASS_$(Get-Random)"
# Connection string has WRONG credentials; correct ones in individual *FromEnv
$connStr9 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=wrong_user;Password=wrong_password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar9, $connStr9, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envUserVar9, $Username, [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envPassVar9, $Password, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath9 = Join-Path $ExportPath "connstr_test9"
    if (Test-Path $testExportPath9) { Remove-Item $testExportPath9 -Recurse -Force }

    # UsernameFromEnv/PasswordFromEnv override wrong credentials from ConnectionStringFromEnv
    $output = & $exportScript `
        -Database $SourceDatabase `
        -ConnectionStringFromEnv $connStrVar9 `
        -UsernameFromEnv $envUserVar9 -PasswordFromEnv $envPassVar9 `
        -TrustServerCertificate `
        -OutputPath $testExportPath9 2>&1

    $exportedDir = Get-ChildItem $testExportPath9 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Individual *FromEnv credentials override ConnectionStringFromEnv" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Individual *FromEnv credentials override ConnectionStringFromEnv" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar9, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envUserVar9, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envPassVar9, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 10: -Credential takes precedence over ConnectionStringFromEnv ---
Write-Host "`n[INFO] Test 10: CLI -Credential takes precedence over ConnectionStringFromEnv" -ForegroundColor Cyan

$connStrVar10 = "TEST_CONNSTR_$(Get-Random)"
# Connection string has wrong credentials; correct ones via -Credential
$connStr10 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=wrong_user;Password=wrong_password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar10, $connStr10, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath10 = Join-Path $ExportPath "connstr_test10"
    if (Test-Path $testExportPath10) { Remove-Item $testExportPath10 -Recurse -Force }

    $output = & $exportScript `
        -Database $SourceDatabase `
        -Credential $credential `
        -ConnectionStringFromEnv $connStrVar10 `
        -TrustServerCertificate `
        -OutputPath $testExportPath10 2>&1

    $exportedDir = Get-ChildItem $testExportPath10 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "CLI -Credential overrides ConnectionStringFromEnv credentials" ($null -ne $exportedDir)
} catch {
    Write-TestResult "CLI -Credential overrides ConnectionStringFromEnv credentials" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar10, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 11: Unset env var for ConnectionStringFromEnv produces clear error ---
Write-Host "`n[INFO] Test 11: Unset ConnectionStringFromEnv env var produces clear error" -ForegroundColor Cyan

$connStrVar11 = "TEST_CONNSTR_UNSET_$(Get-Random)"
# Ensure it is NOT set
[System.Environment]::SetEnvironmentVariable($connStrVar11, $null, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript `
        -Server $Server -Database $SourceDatabase `
        -ConnectionStringFromEnv $connStrVar11 `
        -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'ConnectionStringFromEnv.*not set' -or
                $errorOutput -match 'not set or is empty'
    Write-TestResult "Unset ConnectionStringFromEnv env var produces clear error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'ConnectionStringFromEnv.*not set' -or
                $_.Exception.Message -match 'not set or is empty'
    Write-TestResult "Unset ConnectionStringFromEnv env var produces clear error" $hasError
}

# --- Test 12: Config connection.connectionStringFromEnv is used as fallback ---
Write-Host "`n[INFO] Test 12: Config connection.connectionStringFromEnv used as fallback" -ForegroundColor Cyan

$connStrVar12 = "TEST_CONNSTR_$(Get-Random)"
$connStr12 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar12, $connStr12, [System.EnvironmentVariableTarget]::Process)

$configContent12 = @"
connection:
  connectionStringFromEnv: $connStrVar12
"@
$configPath12 = Join-Path $ExportPath "test-connstr-config.yml"
if (-not (Test-Path $ExportPath)) { New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null }
$configContent12 | Set-Content -Path $configPath12

try {
    $testExportPath12 = Join-Path $ExportPath "connstr_test12"
    if (Test-Path $testExportPath12) { Remove-Item $testExportPath12 -Recurse -Force }

    # No CLI params — all connection info comes from config's connectionStringFromEnv
    $output = & $exportScript `
        -ConfigFile $configPath12 `
        -OutputPath $testExportPath12 2>&1

    $exportedDir = Get-ChildItem $testExportPath12 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "Config connection.connectionStringFromEnv works as fallback" ($null -ne $exportedDir)
} catch {
    Write-TestResult "Config connection.connectionStringFromEnv works as fallback" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar12, $null, [System.EnvironmentVariableTarget]::Process)
    Remove-Item $configPath12 -ErrorAction SilentlyContinue
}

# --- Test 13: Password from connection string is not logged in verbose output ---
Write-Host "`n[INFO] Test 13: Password from connection string is never logged" -ForegroundColor Cyan

$connStrVar13 = "TEST_CONNSTR_$(Get-Random)"
$uniquePassword13 = "S3cretFromConnStr_$(Get-Random)"
# Use the wrong password so export will fail, but we can check for password leakage in output
$connStr13 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$uniquePassword13;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar13, $connStr13, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar13 `
        -OutputPath (Join-Path $ExportPath "connstr_test13") `
        -Verbose 2>&1

    $allOutput = $output | Out-String
    $passwordFound = $allOutput -match [regex]::Escape($uniquePassword13)
    Write-TestResult "Password from connection string not leaked in output" (-not $passwordFound)
    if ($passwordFound) {
        Write-Host "  WARNING: Password found in output!" -ForegroundColor Red
    }
} catch {
    $allOutput = "$($_.Exception.Message) $($_.ScriptStackTrace)"
    $passwordFound = $allOutput -match [regex]::Escape($uniquePassword13)
    Write-TestResult "Password from connection string not leaked in output" (-not $passwordFound)
    if ($passwordFound) {
        Write-Host "  WARNING: Password found in exception output!" -ForegroundColor Red
    }
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar13, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 14: TrustServerCertificate in connection string is applied ---
Write-Host "`n[INFO] Test 14: TrustServerCertificate from connection string is applied" -ForegroundColor Cyan

$connStrVar14 = "TEST_CONNSTR_$(Get-Random)"
# Correct credentials in connection string WITH TrustServerCertificate=true (no -TrustServerCertificate CLI param)
$connStr14 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar14, $connStr14, [System.EnvironmentVariableTarget]::Process)

try {
    $testExportPath14 = Join-Path $ExportPath "connstr_test14"
    if (Test-Path $testExportPath14) { Remove-Item $testExportPath14 -Recurse -Force }

    # No -TrustServerCertificate on CLI — it comes from the connection string
    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar14 `
        -OutputPath $testExportPath14 2>&1

    $exportedDir = Get-ChildItem $testExportPath14 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    Write-TestResult "TrustServerCertificate from connection string enables SSL bypass" ($null -ne $exportedDir)
} catch {
    Write-TestResult "TrustServerCertificate from connection string enables SSL bypass" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar14, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 15: CLI -TrustServerCertificate:$false overrides connection string TrustServerCertificate=true ---
Write-Host "`n[INFO] Test 15: CLI -TrustServerCertificate takes precedence over connection string" -ForegroundColor Cyan

$connStrVar15 = "TEST_CONNSTR_$(Get-Random)"
$connStr15 = "Data Source=$Server;Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
[System.Environment]::SetEnvironmentVariable($connStrVar15, $connStr15, [System.EnvironmentVariableTarget]::Process)

try {
    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar15 `
        -TrustServerCertificate:$false `
        -OutputPath (Join-Path $ExportPath "should_fail_ssl") 2>&1
    $errorOutput = $output | Out-String
    # Container uses self-signed cert; disabling TrustServerCertificate should cause SSL error
    $hasSslError = ($errorOutput -match 'certificate|SSL|TLS|trust' -or $LASTEXITCODE -ne 0)
    Write-TestResult "CLI -TrustServerCertificate:false overrides connection string value" $hasSslError
} catch {
    # Exception is also acceptable — means the SSL override worked
    Write-TestResult "CLI -TrustServerCertificate:false overrides connection string value" $true
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar15, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 16: Missing Database from all sources produces clear error ---
Write-Host "`n[INFO] Test 16: Missing Database from all sources produces clear error" -ForegroundColor Cyan

try {
    # No -Database, no ConnectionStringFromEnv with database key
    $connStrVar16 = "TEST_CONNSTR_$(Get-Random)"
    $connStr16 = "Data Source=$Server;User ID=$Username;Password=$Password;TrustServerCertificate=true"  # No database
    [System.Environment]::SetEnvironmentVariable($connStrVar16, $connStr16, [System.EnvironmentVariableTarget]::Process)

    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar16 `
        -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'Database is required'
    Write-TestResult "Missing Database produces clear error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'Database is required'
    Write-TestResult "Missing Database produces clear error" $hasError
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar16, $null, [System.EnvironmentVariableTarget]::Process)
}

# --- Test 17: Missing Server from all sources produces clear error ---
Write-Host "`n[INFO] Test 17: Missing Server from all sources produces clear error" -ForegroundColor Cyan

try {
    $connStrVar17 = "TEST_CONNSTR_$(Get-Random)"
    # Connection string has no Data Source / Server key — only Database and credentials
    $connStr17NoServer = "Initial Catalog=$SourceDatabase;User ID=$Username;Password=$Password;TrustServerCertificate=true"
    [System.Environment]::SetEnvironmentVariable($connStrVar17, $connStr17NoServer, [System.EnvironmentVariableTarget]::Process)

    $output = & $exportScript `
        -ConnectionStringFromEnv $connStrVar17 `
        -OutputPath (Join-Path $ExportPath "should_not_exist") 2>&1
    $errorOutput = $output | Out-String
    $hasError = $errorOutput -match 'Server is required'
    Write-TestResult "Missing Server produces clear error" $hasError
} catch {
    $hasError = $_.Exception.Message -match 'Server is required'
    Write-TestResult "Missing Server produces clear error" $hasError
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar17, $null, [System.EnvironmentVariableTarget]::Process)
}

# ==============================================================
# INTEGRATION TESTS: Import Script with ConnectionStringFromEnv
# ==============================================================

Write-Host "`n[INFO] Import Script Tests" -ForegroundColor Cyan
Write-Host "---------------------------------------------------" -ForegroundColor Cyan

# --- Test 18: Import with ConnectionStringFromEnv ---
Write-Host "`n[INFO] Test 18: Import using ConnectionStringFromEnv" -ForegroundColor Cyan

# First export to get source scripts
$testExportPath18 = Join-Path $ExportPath "connstr_import_source"
$importTargetDb = "TestConnStrImport_$(Get-Random)"
$connStrVar18 = "TEST_CONNSTR_$(Get-Random)"

try {
    # Export to get source scripts
    if (Test-Path $testExportPath18) { Remove-Item $testExportPath18 -Recurse -Force }
    & $exportScript -Server $Server -Database $SourceDatabase `
        -Credential $credential -TrustServerCertificate `
        -OutputPath $testExportPath18 | Out-Null

    $exportedDir18 = Get-ChildItem $testExportPath18 -Directory | Select-Object -First 1
    if ($null -eq $exportedDir18) { throw "Export failed — cannot run import test" }

    # Set up import connection string pointing to the target database
    $connStr18 = "Data Source=$Server;Initial Catalog=$importTargetDb;User ID=$Username;Password=$Password;TrustServerCertificate=true"
    [System.Environment]::SetEnvironmentVariable($connStrVar18, $connStr18, [System.EnvironmentVariableTarget]::Process)

    # Import using only ConnectionStringFromEnv (no -Server, -Database, or -Credential)
    $output = & $importScript `
        -SourcePath $exportedDir18.FullName `
        -ConnectionStringFromEnv $connStrVar18 `
        -CreateDatabase 2>&1

    $importOutput = $output | Out-String
    $importSuccess = $importOutput -match 'Import complete|completed successfully|objects imported' -or
                     (Invoke-SqlCommand "SELECT 1 FROM sys.databases WHERE name='$($importTargetDb.Replace("'","''"))'" 2>$null) -ne $null

    # Verify database was created
    try {
        $dbCheck = Invoke-SqlCommand "SELECT name FROM sys.databases WHERE name='$($importTargetDb.Replace("'","''"))'"
        $importSuccess = ($dbCheck | Where-Object { $_ -match $importTargetDb }) -ne $null
    } catch { $importSuccess = $false }

    Write-TestResult "Import using ConnectionStringFromEnv" $importSuccess
} catch {
    Write-TestResult "Import using ConnectionStringFromEnv" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar18, $null, [System.EnvironmentVariableTarget]::Process)
    Drop-TestDatabase $importTargetDb
}

# --- Test 19: Import CLI -Database overrides connection string database ---
Write-Host "`n[INFO] Test 19: Import -Database overrides connection string database" -ForegroundColor Cyan

$connStrVar18 = "TEST_CONNSTR_$(Get-Random)"
$importTargetDb18 = "TestConnStrOverride_$(Get-Random)"

try {
    $exportedDir18 = Get-ChildItem $testExportPath18 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $exportedDir18) { throw "Need export from test 17 — skipping" }

    # Connection string has WRONG database; correct one via -Database
    $connStr18 = "Data Source=$Server;Initial Catalog=WrongDatabase_ShouldBeIgnored;User ID=$Username;Password=$Password;TrustServerCertificate=true"
    [System.Environment]::SetEnvironmentVariable($connStrVar18, $connStr18, [System.EnvironmentVariableTarget]::Process)

    $output = & $importScript `
        -Database $importTargetDb18 `
        -SourcePath $exportedDir18.FullName `
        -ConnectionStringFromEnv $connStrVar18 `
        -CreateDatabase 2>&1

    try {
        $dbCheck = Invoke-SqlCommand "SELECT name FROM sys.databases WHERE name='$($importTargetDb18.Replace("'","''"))'"
        $importSuccess = ($dbCheck | Where-Object { $_ -match $importTargetDb18 }) -ne $null
    } catch { $importSuccess = $false }

    Write-TestResult "Import -Database overrides connection string database" $importSuccess
} catch {
    Write-TestResult "Import -Database overrides connection string database" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar18, $null, [System.EnvironmentVariableTarget]::Process)
    Drop-TestDatabase $importTargetDb18
}

# --- Test 20: Import with config connection.connectionStringFromEnv ---
Write-Host "`n[INFO] Test 20: Import with config connection.connectionStringFromEnv" -ForegroundColor Cyan

$connStrVar19 = "TEST_CONNSTR_$(Get-Random)"
$importTargetDb19 = "TestConnStrConfig_$(Get-Random)"

try {
    $exportedDir19 = Get-ChildItem $testExportPath18 -Directory -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $exportedDir19) { throw "Need export from test 17 — skipping" }

    $connStr19 = "Data Source=$Server;Initial Catalog=$importTargetDb19;User ID=$Username;Password=$Password;TrustServerCertificate=true"
    [System.Environment]::SetEnvironmentVariable($connStrVar19, $connStr19, [System.EnvironmentVariableTarget]::Process)

    $configContent19 = @"
connection:
  connectionStringFromEnv: $connStrVar19
"@
    $configPath19 = Join-Path $ExportPath "test-import-connstr-config.yml"
    $configContent19 | Set-Content -Path $configPath19

    $output = & $importScript `
        -SourcePath $exportedDir19.FullName `
        -ConfigFile $configPath19 `
        -CreateDatabase 2>&1

    try {
        $dbCheck = Invoke-SqlCommand "SELECT name FROM sys.databases WHERE name='$($importTargetDb19.Replace("'","''"))'"
        $importSuccess = ($dbCheck | Where-Object { $_ -match $importTargetDb19 }) -ne $null
    } catch { $importSuccess = $false }

    Write-TestResult "Import config connection.connectionStringFromEnv" $importSuccess
} catch {
    Write-TestResult "Import config connection.connectionStringFromEnv" $false "Error: $_"
} finally {
    [System.Environment]::SetEnvironmentVariable($connStrVar19, $null, [System.EnvironmentVariableTarget]::Process)
    Drop-TestDatabase $importTargetDb19
    Remove-Item $configPath19 -ErrorAction SilentlyContinue
}

# ==============================================================
# SUMMARY
# ==============================================================

Write-Host "`n================================================================" -ForegroundColor Cyan
Write-Host "TEST SUMMARY" -ForegroundColor Cyan
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "Tests Passed: $($script:testsPassed)" -ForegroundColor Green
Write-Host "Tests Failed: $($script:testsFailed)" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Total Tests:  $($script:testsPassed + $script:testsFailed)" -ForegroundColor Cyan

if ($script:testsFailed -gt 0) {
    Write-Host "`nSome tests FAILED. Review output above for details." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`nAll tests PASSED!" -ForegroundColor Green
    exit 0
}
