#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the stripFilestream feature for Import-SqlServerSchema.ps1

.DESCRIPTION
    This test validates that the stripFilestream option correctly:
    1. Removes FILESTREAM_ON clauses from table definitions
    2. Converts VARBINARY(MAX) FILESTREAM columns to regular VARBINARY(MAX)
    3. Skips FILESTREAM FileGroup creation
    4. Works with both autoRemap and removeToPrimary FileGroup strategies

    Uses a mock export folder containing FILESTREAM objects to test import
    to a SQL Server Linux container (which does not support FILESTREAM).

.PARAMETER ConfigFile
    Path to .env file with connection settings. Default: .env

.EXAMPLE
    ./test-strip-filestream.ps1
    ./test-strip-filestream.ps1 -ConfigFile ./custom.env
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
$SourcePath = Join-Path $PSScriptRoot "exports_filestream_test"
$AutoRemapConfig = Join-Path $PSScriptRoot "test-filestream-autoremap.yml"
$RemoveToPrimaryConfig = Join-Path $PSScriptRoot "test-filestream-removetoprimary.yml"
$ImportScript = Join-Path $PSScriptRoot ".." "Import-SqlServerSchema.ps1"

# Test database names
$TestDbAutoRemap = "TestDb_FileStream_AutoRemap"
$TestDbRemoveToPrimary = "TestDb_FileStream_RemoveToPrimary"
$TestDbCommandLine = "TestDb_FileStream_CmdLine"

# Test tracking
$testsPassed = 0
$testsFailed = 0
$testResults = @()

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "STRIP FILESTREAM FEATURE TEST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Target: SQL Server on Linux (Docker)" -ForegroundColor Gray
Write-Host "Source: Mock FILESTREAM export data" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

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

function Test-ColumnIsFilestream {
    param(
        [string]$Database,
        [string]$Schema,
        [string]$Table,
        [string]$Column
    )
    
    # Check if column has FILESTREAM attribute
    $result = Invoke-SqlCommand "SELECT c.is_filestream FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id JOIN sys.schemas s ON t.schema_id = s.schema_id WHERE s.name = '$Schema' AND t.name = '$Table' AND c.name = '$Column'" $Database
    # Handle array result - take the numeric line (0 or 1)
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*[01]\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ($result.Trim() -eq "1")
    }
    return $false
}

function Test-FileGroupExists {
    param(
        [string]$Database,
        [string]$FileGroupName
    )
    
    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name = '$FileGroupName'" $Database
    # Handle array result - take the numeric line
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\s*\d+\s*$' } | Select-Object -First 1)
    }
    if ($result) {
        return ($result.Trim() -ne "0")
    }
    return $false
}

function Get-TableCount {
    param([string]$Database)
    
    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $Database
    # Handle array result - take last non-empty line which contains the count
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
    }
    return [int]$result.Trim()
}

function Get-ProcedureCount {
    param([string]$Database)
    
    $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $Database
    # Handle array result - take last non-empty line which contains the count
    if ($result -is [array]) {
        $result = ($result | Where-Object { $_ -match '^\d+$' } | Select-Object -Last 1)
    }
    return [int]$result.Trim()
}

try {
    # ═══════════════════════════════════════════════════════════════
    # SETUP: Verify test prerequisites
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "[INFO] Verifying test prerequisites..." -ForegroundColor Cyan
    
    # Verify source path exists
    if (-not (Test-Path $SourcePath)) {
        throw "Test export folder not found: $SourcePath"
    }
    Write-Host "  [OK] Source path exists: $SourcePath" -ForegroundColor Gray
    
    # Verify config files exist
    if (-not (Test-Path $AutoRemapConfig)) {
        throw "Config file not found: $AutoRemapConfig"
    }
    if (-not (Test-Path $RemoveToPrimaryConfig)) {
        throw "Config file not found: $RemoveToPrimaryConfig"
    }
    Write-Host "  [OK] Config files exist" -ForegroundColor Gray
    
    # Verify import script exists
    if (-not (Test-Path $ImportScript)) {
        throw "Import script not found: $ImportScript"
    }
    Write-Host "  [OK] Import script exists" -ForegroundColor Gray
    
    # Verify SQL Server connection
    try {
        $version = Invoke-SqlCommand "SELECT @@VERSION"
        Write-Host "  [OK] SQL Server connection successful" -ForegroundColor Gray
        if ($version -match "Linux") {
            Write-Host "  [OK] Target is SQL Server on Linux (FILESTREAM not supported)" -ForegroundColor Gray
        }
    }
    catch {
        throw "Cannot connect to SQL Server: $_"
    }
    
    # Clean up any existing test databases
    Write-Host "`n[INFO] Cleaning up existing test databases..." -ForegroundColor Cyan
    Remove-TestDatabase $TestDbAutoRemap
    Remove-TestDatabase $TestDbRemoveToPrimary
    Remove-TestDatabase $TestDbCommandLine
    
    # ═══════════════════════════════════════════════════════════════
    # TEST 1: Import with stripFilestream + autoRemap (config file)
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "TEST 1: stripFilestream + autoRemap (config)" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Yellow
    
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
    
    Write-Host "[INFO] Running import with autoRemap strategy..." -ForegroundColor Cyan
    
    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbAutoRemap `
            -SourcePath $SourcePath `
            -Credential $credential `
            -ConfigFile $AutoRemapConfig `
            -CreateDatabase `
            -Verbose
        
        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }
    
    Write-TestResult -TestName "1.1 Import completes without error (autoRemap)" -Passed $importSuccess
    
    if ($importSuccess) {
        # Test 1.2: Tables created
        $tableCount = Get-TableCount $TestDbAutoRemap
        Write-TestResult -TestName "1.2 All tables created ($tableCount/3)" -Passed ($tableCount -eq 3) -Message "Expected 3, got $tableCount"
        
        # Test 1.3: Documents table exists
        $documentsExists = Test-TableExists $TestDbAutoRemap "dbo" "Documents"
        Write-TestResult -TestName "1.3 dbo.Documents table created" -Passed $documentsExists
        
        # Test 1.4: Content column is NOT FILESTREAM (should be regular VARBINARY)
        if ($documentsExists) {
            $isFilestream = Test-ColumnIsFilestream $TestDbAutoRemap "dbo" "Documents" "Content"
            Write-TestResult -TestName "1.4 Content column is NOT FILESTREAM" -Passed (-not $isFilestream) -Message "Column still has FILESTREAM attribute"
        }
        else {
            Write-TestResult -TestName "1.4 Content column is NOT FILESTREAM" -Passed $false -Message "Table does not exist"
        }
        
        # Test 1.5: FILESTREAM FileGroup NOT created
        $filestreamFgExists = Test-FileGroupExists $TestDbAutoRemap "FG_FILESTREAM"
        Write-TestResult -TestName "1.5 FILESTREAM FileGroup NOT created" -Passed (-not $filestreamFgExists) -Message "FG_FILESTREAM exists but should be skipped"
        
        # Test 1.6: Regular FileGroup created (autoRemap)
        $dataFgExists = Test-FileGroupExists $TestDbAutoRemap "FG_DATA"
        Write-TestResult -TestName "1.6 Regular FileGroup FG_DATA created" -Passed $dataFgExists -Message "FG_DATA should be created with autoRemap"
        
        # Test 1.7: Stored procedures created
        $procCount = Get-ProcedureCount $TestDbAutoRemap
        Write-TestResult -TestName "1.7 Stored procedures created ($procCount/2)" -Passed ($procCount -eq 2) -Message "Expected 2, got $procCount"
    }
    
    # ═══════════════════════════════════════════════════════════════
    # TEST 2: Import with stripFilestream + removeToPrimary (config)
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "TEST 2: stripFilestream + removeToPrimary (config)" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Yellow
    
    Write-Host "[INFO] Running import with removeToPrimary strategy..." -ForegroundColor Cyan
    
    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbRemoveToPrimary `
            -SourcePath $SourcePath `
            -Credential $credential `
            -ConfigFile $RemoveToPrimaryConfig `
            -CreateDatabase `
            -Verbose
        
        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }
    
    Write-TestResult -TestName "2.1 Import completes without error (removeToPrimary)" -Passed $importSuccess
    
    if ($importSuccess) {
        # Test 2.2: Tables created
        $tableCount = Get-TableCount $TestDbRemoveToPrimary
        Write-TestResult -TestName "2.2 All tables created ($tableCount/3)" -Passed ($tableCount -eq 3) -Message "Expected 3, got $tableCount"
        
        # Test 2.3: Attachments table exists (second FILESTREAM table)
        $attachmentsExists = Test-TableExists $TestDbRemoveToPrimary "dbo" "Attachments"
        Write-TestResult -TestName "2.3 dbo.Attachments table created" -Passed $attachmentsExists
        
        # Test 2.4: FileContent column is NOT FILESTREAM
        if ($attachmentsExists) {
            $isFilestream = Test-ColumnIsFilestream $TestDbRemoveToPrimary "dbo" "Attachments" "FileContent"
            Write-TestResult -TestName "2.4 FileContent column is NOT FILESTREAM" -Passed (-not $isFilestream)
        }
        else {
            Write-TestResult -TestName "2.4 FileContent column is NOT FILESTREAM" -Passed $false -Message "Table does not exist"
        }
        
        # Test 2.5: NO custom FileGroups (removeToPrimary skips all)
        $dataFgExists = Test-FileGroupExists $TestDbRemoveToPrimary "FG_DATA"
        Write-TestResult -TestName "2.5 FG_DATA NOT created (removeToPrimary)" -Passed (-not $dataFgExists) -Message "FG_DATA exists but should be remapped to PRIMARY"
        
        # Test 2.6: FILESTREAM FileGroup NOT created
        $filestreamFgExists = Test-FileGroupExists $TestDbRemoveToPrimary "FG_FILESTREAM"
        Write-TestResult -TestName "2.6 FILESTREAM FileGroup NOT created" -Passed (-not $filestreamFgExists)
    }
    
    # ═══════════════════════════════════════════════════════════════
    # TEST 3: Import with -StripFilestream command-line parameter
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "TEST 3: -StripFilestream command-line parameter" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Yellow
    
    Write-Host "[INFO] Running import with -StripFilestream parameter..." -ForegroundColor Cyan
    
    try {
        & $ImportScript `
            -Server $Server `
            -Database $TestDbCommandLine `
            -SourcePath $SourcePath `
            -Credential $credential `
            -CreateDatabase `
            -StripFilestream `
            -Verbose
        
        $importSuccess = $true
    }
    catch {
        Write-Host "[ERROR] Import failed: $_" -ForegroundColor Red
        $importSuccess = $false
    }
    
    Write-TestResult -TestName "3.1 Import completes with -StripFilestream param" -Passed $importSuccess
    
    if ($importSuccess) {
        # Test 3.2: Tables created
        $tableCount = Get-TableCount $TestDbCommandLine
        Write-TestResult -TestName "3.2 All tables created ($tableCount/3)" -Passed ($tableCount -eq 3)
        
        # Test 3.3: Content column is NOT FILESTREAM
        $isFilestream = Test-ColumnIsFilestream $TestDbCommandLine "dbo" "Documents" "Content"
        Write-TestResult -TestName "3.3 FILESTREAM stripped via command-line" -Passed (-not $isFilestream)
    }
    
    # ═══════════════════════════════════════════════════════════════
    # TEST 4: Config format variations (YAML syntax alternatives)
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "TEST 4: Config format variations" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Yellow
    
    # Test different YAML formats that should all work
    $configVariations = @(
        @{ Name = "Flow style (inline)"; Config = "test-filestream-variations.yml"; Db = "TestDb_FS_FlowStyle" },
        @{ Name = "Quoted string 'true'"; Config = "test-filestream-quoted.yml"; Db = "TestDb_FS_Quoted" },
        @{ Name = "Integer 1"; Config = "test-filestream-integer.yml"; Db = "TestDb_FS_Integer" },
        @{ Name = "4-space indent"; Config = "test-filestream-4space.yml"; Db = "TestDb_FS_4Space" }
    )
    
    foreach ($variation in $configVariations) {
        $configPath = Join-Path $PSScriptRoot $variation.Config
        $testDb = $variation.Db
        
        Write-Host "[INFO] Testing: $($variation.Name)..." -ForegroundColor Cyan
        
        # Clean up any existing test database
        Remove-TestDatabase $testDb
        
        try {
            & $ImportScript `
                -Server $Server `
                -Database $testDb `
                -SourcePath $SourcePath `
                -Credential $credential `
                -ConfigFile $configPath `
                -CreateDatabase `
                -Verbose:$false
            
            # Verify FILESTREAM was stripped
            $isFilestream = Test-ColumnIsFilestream $testDb "dbo" "Documents" "Content"
            $success = -not $isFilestream
            
            Write-TestResult -TestName "4.x $($variation.Name)" -Passed $success -Message $(if (-not $success) { "FILESTREAM not stripped" } else { "" })
        }
        catch {
            Write-TestResult -TestName "4.x $($variation.Name)" -Passed $false -Message "Import failed: $_"
        }
        finally {
            # Clean up
            Remove-TestDatabase $testDb
        }
    }
    
    # ═══════════════════════════════════════════════════════════════
    # TEST SUMMARY
    # ═══════════════════════════════════════════════════════════════
    
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan
    
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
        Remove-TestDatabase $TestDbAutoRemap
        Remove-TestDatabase $TestDbRemoveToPrimary
        Remove-TestDatabase $TestDbCommandLine
    }
    catch {
        Write-Host "  [WARNING] Cleanup failed: $_" -ForegroundColor Yellow
    }
}
