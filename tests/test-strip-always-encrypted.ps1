#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the StripAlwaysEncrypted feature for Import-SqlServerSchema.ps1

.DESCRIPTION
    This test validates that the StripAlwaysEncrypted option correctly:
    1. Removes ENCRYPTED WITH clauses from column definitions (single-line and multi-line)
    2. Skips CREATE COLUMN MASTER KEY and CREATE COLUMN ENCRYPTION KEY statements
    3. Allows data INSERT/SELECT on formerly encrypted columns
    4. Leaves non-encrypted tables unaffected
    5. Works with both command-line parameter and config file

    Uses fixture export data in tests/fixtures/always_encrypted_test containing
    Always Encrypted objects to test import to a SQL Server target without
    access to the original key store.

.PARAMETER ConfigFile
    Path to .env file with connection settings. Default: .env

.EXAMPLE
    ./test-strip-always-encrypted.ps1
    ./test-strip-always-encrypted.ps1 -ConfigFile ./custom.env
#>

param(
    [string]$ConfigFile = ".env"
)

$ErrorActionPreference = "Stop"

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
}
else {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

# Configuration
$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourcePath = Join-Path $PSScriptRoot "fixtures" "always_encrypted_test"
$AeConfigFile = Join-Path $PSScriptRoot "test-always-encrypted-config.yml"
$ImportScript = Join-Path $PSScriptRoot ".." "Import-SqlServerSchema.ps1"

# Test database names
$TestDbCmdLine = "TestDb_AE_CmdLine"
$TestDbConfig = "TestDb_AE_Config"
$TestDbBaseline = "TestDb_AE_Baseline"

# Test tracking
$testsPassed = 0
$testsFailed = 0
$testResults = @()

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "STRIP ALWAYS ENCRYPTED FEATURE TEST" -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "Target: SQL Server (Docker)" -ForegroundColor Gray
Write-Host "Source: fixtures/always_encrypted_test" -ForegroundColor Gray
Write-Host "===============================================`n" -ForegroundColor Cyan

# Helper function to execute SQL
function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )

    $sqlcmdArgs = @('-S', $Server, '-U', $Username, '-P', $Password, '-d', $Database, '-C', '-Q', $Query, '-h', '-1', '-W')
    $result = & sqlcmd @sqlcmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL command failed: $result"
    }
    return $result
}

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )

    $script:testResults += @{
        Name    = $TestName
        Passed  = $Passed
        Message = $Message
    }

    if ($Passed) {
        $script:testsPassed++
        Write-Host "[PASS] $TestName" -ForegroundColor Green
    }
    else {
        $script:testsFailed++
        Write-Host "[FAIL] $TestName" -ForegroundColor Red
        if ($Message) {
            Write-Host "       $Message" -ForegroundColor Yellow
        }
    }
}

function Remove-TestDatabase {
    param([string]$DatabaseName)

    try {
        $exists = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.databases WHERE name = '$DatabaseName'"
        if ($exists -and $exists.Trim() -ne "0") {
            Invoke-SqlCommand "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DatabaseName]"
            Write-Host "  Dropped existing database: $DatabaseName" -ForegroundColor Gray
        }
    }
    catch {
        # Ignore errors - database might not exist
    }
}

function Test-TableExists {
    param(
        [string]$Database,
        [string]$Schema,
        [string]$Table
    )

    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables t JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = '$Schema' AND t.name = '$Table'" $Database
    # Handle array result - take the numeric line
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ($result.Trim() -ne "0")
    }
    return $false
}

function Test-ColumnIsEncrypted {
    param(
        [string]$Database,
        [string]$Schema,
        [string]$Table,
        [string]$Column
    )

    # Check sys.columns.encryption_type: 0 = not encrypted, 1 = deterministic, 2 = randomized
    $result = Invoke-SqlCommand "SELECT c.encryption_type FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = '$Schema' AND t.name = '$Table' AND c.name = '$Column'" $Database
    # Handle array result - take the numeric line
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ($result.Trim() -ne "0")
    }
    return $false
}

function Test-CmkExists {
    param([string]$Database)

    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.column_master_keys" $Database
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ([int]$result.Trim() -gt 0)
    }
    return $false
}

function Test-CekExists {
    param([string]$Database)

    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.column_encryption_keys" $Database
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ([int]$result.Trim() -gt 0)
    }
    return $false
}

function Get-TableCount {
    param([string]$Database)

    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $Database
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    return [int]$result.Trim()
}

function Get-ColumnCount {
    param(
        [string]$Database,
        [string]$Schema,
        [string]$Table
    )

    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = '$Schema' AND t.name = '$Table'" $Database
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    return [int]$result.Trim()
}

try {
    # ===============================================================
    # SETUP: Verify test prerequisites
    # ===============================================================

    Write-Host "[INFO] Verifying test prerequisites..." -ForegroundColor Cyan

    # Verify source path exists
    if (-not (Test-Path $SourcePath)) {
        throw "Test export folder not found: $SourcePath"
    }
    Write-Host "  [OK] Source path exists: $SourcePath" -ForegroundColor Gray

    # Verify config file exists
    if (-not (Test-Path $AeConfigFile)) {
        throw "Config file not found: $AeConfigFile"
    }
    Write-Host "  [OK] Config file exists: $AeConfigFile" -ForegroundColor Gray

    # Verify import script exists
    if (-not (Test-Path $ImportScript)) {
        throw "Import script not found: $ImportScript"
    }
    Write-Host "  [OK] Import script exists" -ForegroundColor Gray

    # Verify SQL Server connection
    try {
        $version = Invoke-SqlCommand "SELECT @@VERSION"
        Write-Host "  [OK] SQL Server connection successful" -ForegroundColor Gray
    }
    catch {
        throw "Cannot connect to SQL Server: $_"
    }

    # Clean up any existing test databases
    Write-Host "`n[INFO] Cleaning up existing test databases..." -ForegroundColor Cyan
    Remove-TestDatabase $TestDbCmdLine
    Remove-TestDatabase $TestDbConfig
    Remove-TestDatabase $TestDbBaseline

    # ===============================================================
    # TEST 1: Import with -StripAlwaysEncrypted command-line parameter
    # ===============================================================

    Write-Host "`n===============================================" -ForegroundColor Yellow
    Write-Host "TEST 1: -StripAlwaysEncrypted command-line parameter" -ForegroundColor Yellow
    Write-Host "===============================================`n" -ForegroundColor Yellow

    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    Write-Host "[INFO] Running import with -StripAlwaysEncrypted parameter..." -ForegroundColor Cyan

    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbCmdLine `
            -SourcePath $SourcePath `
            -Credential $credential `
            -CreateDatabase `
            -StripAlwaysEncrypted `
            -Verbose

        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }

    Write-TestResult -TestName "1.1 Import completes without error (-StripAlwaysEncrypted)" -Passed $importSuccess

    if ($importSuccess) {
        # Test 1.2: All tables created
        $tableCount = Get-TableCount $TestDbCmdLine
        Write-TestResult -TestName "1.2 All tables created ($tableCount/3)" -Passed ($tableCount -eq 3) -Message "Expected 3, got $tableCount"

        # Test 1.3: No CMK objects exist
        $cmkExists = Test-CmkExists $TestDbCmdLine
        Write-TestResult -TestName "1.3 No Column Master Key objects exist" -Passed (-not $cmkExists) -Message "CMK objects found but should be stripped"

        # Test 1.4: No CEK objects exist
        $cekExists = Test-CekExists $TestDbCmdLine
        Write-TestResult -TestName "1.4 No Column Encryption Key objects exist" -Passed (-not $cekExists) -Message "CEK objects found but should be stripped"

        # Test 1.5: EncryptedTable.SSN column is NOT encrypted
        $ssnEncrypted = Test-ColumnIsEncrypted $TestDbCmdLine "dbo" "EncryptedTable" "SSN"
        Write-TestResult -TestName "1.5 EncryptedTable.SSN is NOT encrypted" -Passed (-not $ssnEncrypted) -Message "SSN column still marked as encrypted"

        # Test 1.6: EncryptedTable.Salary column is NOT encrypted
        $salaryEncrypted = Test-ColumnIsEncrypted $TestDbCmdLine "dbo" "EncryptedTable" "Salary"
        Write-TestResult -TestName "1.6 EncryptedTable.Salary is NOT encrypted" -Passed (-not $salaryEncrypted) -Message "Salary column still marked as encrypted"

        # Test 1.7: MultiLineEncrypted.TaxId column is NOT encrypted (multi-line variation)
        $taxIdEncrypted = Test-ColumnIsEncrypted $TestDbCmdLine "dbo" "MultiLineEncrypted" "TaxId"
        Write-TestResult -TestName "1.7 MultiLineEncrypted.TaxId is NOT encrypted (multi-line)" -Passed (-not $taxIdEncrypted) -Message "TaxId column still marked as encrypted"

        # Test 1.8: RegularTable columns unaffected
        $regularExists = Test-TableExists $TestDbCmdLine "dbo" "RegularTable"
        $regularColCount = Get-ColumnCount $TestDbCmdLine "dbo" "RegularTable"
        Write-TestResult -TestName "1.8 RegularTable unaffected (exists, $regularColCount columns)" -Passed ($regularExists -and $regularColCount -eq 3) -Message "Expected table with 3 columns"

        # Test 1.9: INSERT data into EncryptedTable succeeds
        try {
            Invoke-SqlCommand "INSERT INTO [dbo].[EncryptedTable] ([SSN], [Salary], [Name]) VALUES ('123-45-6789', 75000.00, 'Test User')" $TestDbCmdLine
            Write-TestResult -TestName "1.9 INSERT into EncryptedTable succeeds" -Passed $true
        }
        catch {
            Write-TestResult -TestName "1.9 INSERT into EncryptedTable succeeds" -Passed $false -Message "INSERT failed: $_"
        }

        # Test 1.10: INSERT data into MultiLineEncrypted succeeds
        try {
            Invoke-SqlCommand "INSERT INTO [dbo].[MultiLineEncrypted] ([TaxId], [Notes]) VALUES ('98-7654321', 'Test note')" $TestDbCmdLine
            Write-TestResult -TestName "1.10 INSERT into MultiLineEncrypted succeeds" -Passed $true
        }
        catch {
            Write-TestResult -TestName "1.10 INSERT into MultiLineEncrypted succeeds" -Passed $false -Message "INSERT failed: $_"
        }

        # Test 1.11: SELECT data back from EncryptedTable returns expected values
        try {
            $selectResult = Invoke-SqlCommand "SELECT [SSN], [Name] FROM [dbo].[EncryptedTable] WHERE [Name] = 'Test User'" $TestDbCmdLine
            $selectStr = if ($selectResult -is [array]) { $selectResult -join ' ' } else { $selectResult }
            $hasExpectedData = ($selectStr -match '123-45-6789') -and ($selectStr -match 'Test User')
            Write-TestResult -TestName "1.11 SELECT from EncryptedTable returns expected values" -Passed $hasExpectedData -Message "Unexpected result: $selectStr"
        }
        catch {
            Write-TestResult -TestName "1.11 SELECT from EncryptedTable returns expected values" -Passed $false -Message "SELECT failed: $_"
        }
    }

    # ===============================================================
    # TEST 2: Import with config file (stripAlwaysEncrypted: true)
    # ===============================================================

    Write-Host "`n===============================================" -ForegroundColor Yellow
    Write-Host "TEST 2: stripAlwaysEncrypted via config file" -ForegroundColor Yellow
    Write-Host "===============================================`n" -ForegroundColor Yellow

    Write-Host "[INFO] Running import with config file..." -ForegroundColor Cyan

    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbConfig `
            -SourcePath $SourcePath `
            -Credential $credential `
            -ConfigFile $AeConfigFile `
            -CreateDatabase `
            -Verbose

        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }

    Write-TestResult -TestName "2.1 Import completes without error (config file)" -Passed $importSuccess

    if ($importSuccess) {
        # Test 2.2: Tables created
        $tableCount = Get-TableCount $TestDbConfig
        Write-TestResult -TestName "2.2 All tables created ($tableCount/3)" -Passed ($tableCount -eq 3) -Message "Expected 3, got $tableCount"

        # Test 2.3: No CMK/CEK objects
        $cmkExists = Test-CmkExists $TestDbConfig
        $cekExists = Test-CekExists $TestDbConfig
        Write-TestResult -TestName "2.3 No CMK/CEK objects (config-driven strip)" -Passed (-not $cmkExists -and -not $cekExists) -Message "CMK exists: $cmkExists, CEK exists: $cekExists"

        # Test 2.4: Columns not encrypted
        $ssnEncrypted = Test-ColumnIsEncrypted $TestDbConfig "dbo" "EncryptedTable" "SSN"
        $taxIdEncrypted = Test-ColumnIsEncrypted $TestDbConfig "dbo" "MultiLineEncrypted" "TaxId"
        Write-TestResult -TestName "2.4 Columns not encrypted (config-driven strip)" -Passed (-not $ssnEncrypted -and -not $taxIdEncrypted) -Message "SSN encrypted: $ssnEncrypted, TaxId encrypted: $taxIdEncrypted"

        # Test 2.5: INSERT data succeeds
        try {
            Invoke-SqlCommand "INSERT INTO [dbo].[EncryptedTable] ([SSN], [Salary], [Name]) VALUES ('987-65-4321', 50000.00, 'Config Test')" $TestDbConfig
            Write-TestResult -TestName "2.5 INSERT succeeds (config-driven strip)" -Passed $true
        }
        catch {
            Write-TestResult -TestName "2.5 INSERT succeeds (config-driven strip)" -Passed $false -Message "INSERT failed: $_"
        }
    }

    # ===============================================================
    # TEST 3: Import WITHOUT stripping (baseline - verifies fixtures)
    # ===============================================================

    Write-Host "`n===============================================" -ForegroundColor Yellow
    Write-Host "TEST 3: Baseline (no stripping - verify fixtures)" -ForegroundColor Yellow
    Write-Host "===============================================`n" -ForegroundColor Yellow

    Write-Host "[INFO] Running import without stripping (baseline)..." -ForegroundColor Cyan

    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbBaseline `
            -SourcePath $SourcePath `
            -Credential $credential `
            -CreateDatabase `
            -Verbose

        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }

    Write-TestResult -TestName "3.1 Baseline import completes (CMK/CEK metadata is valid DDL)" -Passed $importSuccess

    if ($importSuccess) {
        # Test 3.2: CMK objects DO exist
        $cmkExists = Test-CmkExists $TestDbBaseline
        Write-TestResult -TestName "3.2 CMK objects exist (baseline)" -Passed $cmkExists -Message "No CMK objects found - fixtures may be broken"

        # Test 3.3: CEK objects DO exist
        $cekExists = Test-CekExists $TestDbBaseline
        Write-TestResult -TestName "3.3 CEK objects exist (baseline)" -Passed $cekExists -Message "No CEK objects found - fixtures may be broken"

        # Test 3.4: Columns ARE marked encrypted
        $ssnEncrypted = Test-ColumnIsEncrypted $TestDbBaseline "dbo" "EncryptedTable" "SSN"
        $salaryEncrypted = Test-ColumnIsEncrypted $TestDbBaseline "dbo" "EncryptedTable" "Salary"
        $taxIdEncrypted = Test-ColumnIsEncrypted $TestDbBaseline "dbo" "MultiLineEncrypted" "TaxId"
        Write-TestResult -TestName "3.4 Columns are marked encrypted (baseline)" -Passed ($ssnEncrypted -and $salaryEncrypted -and $taxIdEncrypted) -Message "SSN: $ssnEncrypted, Salary: $salaryEncrypted, TaxId: $taxIdEncrypted"
    }

    # ===============================================================
    # TEST SUMMARY
    # ===============================================================

    Write-Host "`n===============================================" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "===============================================`n" -ForegroundColor Cyan

    $totalTests = $testsPassed + $testsFailed
    Write-Host "Total Tests: $totalTests" -ForegroundColor White
    Write-Host "Passed: $testsPassed" -ForegroundColor Green
    Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Gray" })

    Write-Host ""

    if ($testsFailed -eq 0) {
        Write-Host "[SUCCESS] All tests passed!" -ForegroundColor Green
        exit 0
    }
    else {
        Write-Host "[FAILURE] Some tests failed:" -ForegroundColor Red
        $testResults | Where-Object { -not $_.Passed } | ForEach-Object {
            Write-Host "  - $($_.Name)" -ForegroundColor Red
            if ($_.Message) {
                Write-Host "    $($_.Message)" -ForegroundColor Yellow
            }
        }
        exit 1
    }
}
catch {
    Write-Host "`n[FATAL] Test script failed: $_" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
}
finally {
    # Clean up test databases (optional - comment out to inspect)
    Write-Host "`n[INFO] Cleaning up test databases..." -ForegroundColor Gray
    try {
        Remove-TestDatabase $TestDbCmdLine
        Remove-TestDatabase $TestDbConfig
        Remove-TestDatabase $TestDbBaseline
    }
    catch {
        Write-Host "  [WARNING] Cleanup failed: $_" -ForegroundColor Yellow
    }
}
