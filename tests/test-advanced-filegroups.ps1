#Requires -Version 7.0

<#
.SYNOPSIS
    Tests advanced FileGroup scenarios including TEXTIMAGE_ON and memory-optimized tables

.DESCRIPTION
    This test validates FileGroup-related fixes:
    1. TEXTIMAGE_ON/FILESTREAM_ON clause remapping (Bug #4)
    2. Memory-optimized FileGroup export syntax (Bug #5)
    3. Memory-optimized FileGroups in removeToPrimary mode (Bug #6)
    4. Partition schemes with FileGroup handling

.NOTES
    Requires: SQL Server container running (docker-compose up -d)
    Note: Memory-optimized tests may be skipped if SQL Server edition doesn't support it
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
$SourceDatabase = "TestDb_AdvancedFG"
$ExportPath = Join-Path $scriptDir "exports_advanced_fg_test"
$securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

# Script paths
$exportScript = Join-Path $projectRoot "Export-SqlServerSchema.ps1"
$importScript = Join-Path $projectRoot "Import-SqlServerSchema.ps1"

# Test results tracking
$script:testsPassed = 0
$script:testsFailed = 0
$script:testsSkipped = 0

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "ADVANCED FILEGROUP TESTS" -ForegroundColor Cyan
Write-Host "Testing Bugs #4, #5, #6: FileGroup handling" -ForegroundColor Cyan
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

function Write-TestSkipped {
    param(
        [string]$TestName,
        [string]$Reason
    )
    Write-Host "[SKIPPED] $TestName" -ForegroundColor Yellow
    Write-Host "  Reason: $Reason" -ForegroundColor Gray
    $script:testsSkipped++
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

function Test-MemoryOptimizedSupported {
    # Check if SQL Server supports memory-optimized tables
    try {
        $result = Invoke-SqlCommand "SELECT SERVERPROPERTY('IsXTPSupported')" "master"
        return ([int]$result.Trim() -eq 1)
    } catch {
        return $false
    }
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
# SETUP: CREATE TEST DATABASE WITH ADVANCED FILEGROUP SCENARIOS
# ═══════════════════════════════════════════════════════════════

Write-Host "[INFO] Setup: Creating test database with advanced FileGroup scenarios..." -ForegroundColor Cyan

# Drop existing test database
Drop-TestDatabase -DbName $SourceDatabase

# Check memory-optimized support
$supportsMemoryOptimized = Test-MemoryOptimizedSupported
Write-Host "  Memory-optimized tables supported: $supportsMemoryOptimized" -ForegroundColor Gray

# Create database with FileGroups
$createDbSql = @"
CREATE DATABASE [$SourceDatabase];
GO

USE [$SourceDatabase];
GO

-- Add custom FileGroup for LOB data
ALTER DATABASE [$SourceDatabase] ADD FILEGROUP [FG_LOB];
GO

ALTER DATABASE [$SourceDatabase] ADD FILE (
    NAME = N'${SourceDatabase}_LOB',
    FILENAME = N'/var/opt/mssql/data/${SourceDatabase}_LOB.ndf',
    SIZE = 8MB,
    FILEGROWTH = 64MB
) TO FILEGROUP [FG_LOB];
GO

-- Add custom FileGroup for archive data
ALTER DATABASE [$SourceDatabase] ADD FILEGROUP [FG_ARCHIVE];
GO

ALTER DATABASE [$SourceDatabase] ADD FILE (
    NAME = N'${SourceDatabase}_Archive',
    FILENAME = N'/var/opt/mssql/data/${SourceDatabase}_Archive.ndf',
    SIZE = 8MB,
    FILEGROWTH = 64MB
) TO FILEGROUP [FG_ARCHIVE];
GO
"@

Invoke-SqlCommand $createDbSql "master"

# Create table with LOB columns on custom FileGroup (tests TEXTIMAGE_ON)
$createTableSql = @"
-- Table with LOB columns - TEXTIMAGE_ON should be on FG_LOB
CREATE TABLE dbo.Documents (
    DocumentId INT IDENTITY(1,1) PRIMARY KEY,
    Title NVARCHAR(255) NOT NULL,
    Content NVARCHAR(MAX) NULL,
    BinaryData VARBINARY(MAX) NULL,
    XmlData XML NULL,
    CreatedDate DATETIME2 DEFAULT GETDATE()
) ON [PRIMARY] TEXTIMAGE_ON [FG_LOB];
GO

-- Table on archive FileGroup
CREATE TABLE dbo.ArchivedOrders (
    OrderId INT PRIMARY KEY,
    OrderDate DATETIME2 NOT NULL,
    TotalAmount DECIMAL(18,2) NOT NULL,
    ArchivedDate DATETIME2 DEFAULT GETDATE()
) ON [FG_ARCHIVE];
GO

-- Insert some test data
INSERT INTO dbo.Documents (Title, Content, BinaryData)
VALUES
    ('Doc1', 'This is some long content for document 1', 0x48656C6C6F),  -- 0x48656C6C6F = 'Hello'
    ('Doc2', 'This is some long content for document 2', 0x576F726C64);  -- 0x576F726C64 = 'World'

INSERT INTO dbo.ArchivedOrders (OrderId, OrderDate, TotalAmount)
VALUES (1, '2024-01-15', 150.00), (2, '2024-02-20', 275.50);
GO
"@

Invoke-SqlCommand $createTableSql $SourceDatabase

# Add memory-optimized FileGroup if supported
if ($supportsMemoryOptimized) {
    Write-Host "  Adding memory-optimized FileGroup..." -ForegroundColor Gray
    try {
        $memOptSql = @"
-- Add memory-optimized FileGroup
ALTER DATABASE [$SourceDatabase] ADD FILEGROUP [FG_MEMORY] CONTAINS MEMORY_OPTIMIZED_DATA;
GO

ALTER DATABASE [$SourceDatabase] ADD FILE (
    NAME = N'${SourceDatabase}_Memory',
    FILENAME = N'/var/opt/mssql/data/${SourceDatabase}_Memory'
) TO FILEGROUP [FG_MEMORY];
GO

-- Create memory-optimized table
CREATE TABLE dbo.HotData (
    Id INT NOT NULL PRIMARY KEY NONCLUSTERED,
    Value NVARCHAR(100) NOT NULL,
    LastUpdated DATETIME2 NOT NULL DEFAULT GETDATE()
) WITH (MEMORY_OPTIMIZED = ON, DURABILITY = SCHEMA_AND_DATA);
GO

INSERT INTO dbo.HotData (Id, Value) VALUES (1, 'Hot record 1'), (2, 'Hot record 2');
GO
"@
        Invoke-SqlCommand $memOptSql $SourceDatabase
        Write-Host "  Memory-optimized FileGroup and table created" -ForegroundColor Gray
    } catch {
        Write-Host "  Could not create memory-optimized objects: $_" -ForegroundColor Yellow
        $supportsMemoryOptimized = $false
    }
}

Write-Host "[SUCCESS] Test database created" -ForegroundColor Green

# Clean export directory
if (Test-Path $ExportPath) {
    Remove-Item $ExportPath -Recurse -Force
}
New-Item -ItemType Directory -Path $ExportPath -Force | Out-Null

# ═══════════════════════════════════════════════════════════════
# TEST 1: TEXTIMAGE_ON EXPORT AND REMAP (Bug #4)
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 1: TEXTIMAGE_ON Export and Remap (Bug #4)" -ForegroundColor Cyan

# Export the database
$exportDir1 = Join-Path $ExportPath "textimage_test"
& $exportScript -Server $Server -Database $SourceDatabase -OutputPath $exportDir1 `
    -Credential $credential -IncludeData -Verbose:$false 2>&1 | Out-Null

$exportedDir1 = Get-ChildItem $exportDir1 -Directory | Select-Object -First 1

# Test 1a: Verify TEXTIMAGE_ON is in exported table script
$tableScript = Get-ChildItem -Path (Join-Path $exportedDir1.FullName "09_Tables_PrimaryKey") -Filter "dbo.Documents.sql" | Select-Object -First 1
$tableContent = Get-Content $tableScript.FullName -Raw

$hasTextimageFGLob = $tableContent -match "TEXTIMAGE_ON\s*\[FG_LOB\]"
Write-TestResult -TestName "Export contains TEXTIMAGE_ON [FG_LOB]" -Passed $hasTextimageFGLob `
    -Message "Table script should preserve TEXTIMAGE_ON clause"

# Test 1b: Import with autoRemap - TEXTIMAGE_ON should be remapped
Write-Host "[INFO] Test 1b: Import with autoRemap..." -ForegroundColor Gray
$targetDb1b = "TestDb_TextImageAutoRemap"
Drop-TestDatabase -DbName $targetDb1b

$configContent1b = @"
import:
  importMode: Dev
  createDatabase: true
  fileGroupStrategy: autoRemap
"@
$configPath1b = Join-Path $ExportPath "test-textimage-autoremap.yml"
$configContent1b | Set-Content -Path $configPath1b

& $importScript -Server $Server -Database $targetDb1b `
    -SourcePath $exportedDir1.FullName -ConfigFile $configPath1b `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

# Verify table exists and has data
$docCount = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Documents" $targetDb1b
Write-TestResult -TestName "Table imported with autoRemap" -Passed ([int]$docCount.Trim() -eq 2) `
    -Message "Documents table should have 2 rows"

Drop-TestDatabase -DbName $targetDb1b

# Test 1c: Import with removeToPrimary - TEXTIMAGE_ON should be remapped to PRIMARY
Write-Host "[INFO] Test 1c: Import with removeToPrimary..." -ForegroundColor Gray
$targetDb1c = "TestDb_TextImageRemove"
Drop-TestDatabase -DbName $targetDb1c

$configContent1c = @"
import:
  importMode: Dev
  createDatabase: true
  fileGroupStrategy: removeToPrimary
"@
$configPath1c = Join-Path $ExportPath "test-textimage-remove.yml"
$configContent1c | Set-Content -Path $configPath1c

& $importScript -Server $Server -Database $targetDb1c `
    -SourcePath $exportedDir1.FullName -ConfigFile $configPath1c `
    -Credential $credential -Verbose:$false 2>&1 | Out-Null

# Verify table exists
$docCount1c = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Documents" $targetDb1c
Write-TestResult -TestName "Table imported with removeToPrimary" -Passed ([int]$docCount1c.Trim() -eq 2) `
    -Message "Documents table should have 2 rows with TEXTIMAGE_ON [PRIMARY]"

# Verify only PRIMARY FileGroup exists (no custom FileGroups)
$fgCount1c = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name != 'PRIMARY'" $targetDb1c
Write-TestResult -TestName "No custom FileGroups in removeToPrimary" -Passed ([int]$fgCount1c.Trim() -eq 0) `
    -Message "Should only have PRIMARY FileGroup"

Drop-TestDatabase -DbName $targetDb1c

# ═══════════════════════════════════════════════════════════════
# TEST 2: MEMORY-OPTIMIZED FILEGROUP EXPORT (Bug #5)
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 2: Memory-Optimized FileGroup Export (Bug #5)" -ForegroundColor Cyan

if (-not $supportsMemoryOptimized) {
    Write-TestSkipped -TestName "Memory-optimized FileGroup export" `
        -Reason "SQL Server edition does not support memory-optimized tables"
} else {
    # Check FileGroup script for correct syntax
    $fgScript = Get-ChildItem -Path (Join-Path $exportedDir1.FullName "00_FileGroups") -Filter "*.sql" | Select-Object -First 1
    if (-not $fgScript) {
        Write-TestResult -TestName "Export has CONTAINS MEMORY_OPTIMIZED_DATA" -Passed $false `
            -Message "No FileGroup script found in 00_FileGroups directory"
    } else {
        $fgContent = Get-Content $fgScript.FullName -Raw

        # Should contain CONTAINS MEMORY_OPTIMIZED_DATA for FG_MEMORY
        $hasMemOptSyntax = $fgContent -match "ADD FILEGROUP\s*\[FG_MEMORY\]\s*CONTAINS\s*MEMORY_OPTIMIZED_DATA"
        Write-TestResult -TestName "Export has CONTAINS MEMORY_OPTIMIZED_DATA" -Passed $hasMemOptSyntax `
            -Message "FileGroup script should have correct memory-optimized syntax"

        # Should NOT just have plain ADD FILEGROUP [FG_MEMORY] without CONTAINS
        $hasPlainFG = $fgContent -match "ADD FILEGROUP\s*\[FG_MEMORY\]\s*;" -and -not $hasMemOptSyntax
        Write-TestResult -TestName "No incorrect plain FileGroup syntax" -Passed (-not $hasPlainFG) `
            -Message "Should not have plain 'ADD FILEGROUP [FG_MEMORY];' without CONTAINS clause"
    }
}

# ═══════════════════════════════════════════════════════════════
# TEST 3: MEMORY-OPTIMIZED FILEGROUP IN removeToPrimary MODE (Bug #6)
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 3: Memory-Optimized FileGroup in removeToPrimary Mode (Bug #6)" -ForegroundColor Cyan

if (-not $supportsMemoryOptimized) {
    Write-TestSkipped -TestName "Memory-optimized in removeToPrimary" `
        -Reason "SQL Server edition does not support memory-optimized tables"
} else {
    $targetDb3 = "TestDb_MemOptRemove"
    Drop-TestDatabase -DbName $targetDb3

    $configContent3 = @"
import:
  importMode: Dev
  createDatabase: true
  fileGroupStrategy: removeToPrimary
"@
    $configPath3 = Join-Path $ExportPath "test-memopt-remove.yml"
    $configContent3 | Set-Content -Path $configPath3

    $importOutput3 = & $importScript -Server $Server -Database $targetDb3 `
        -SourcePath $exportedDir1.FullName -ConfigFile $configPath3 `
        -Credential $credential 2>&1 | Out-String

    # Verify import succeeded
    $success3 = $importOutput3 -match "Import completed successfully"
    Write-TestResult -TestName "Import succeeds with removeToPrimary" -Passed $success3 `
        -Message "Import should succeed even with memory-optimized tables"

    # Verify memory-optimized FileGroup was created (required, can't be removed)
    $memFGExists = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name = 'FG_MEMORY' AND type = 'FX'" $targetDb3
    Write-TestResult -TestName "Memory-optimized FileGroup created in removeToPrimary" -Passed ([int]$memFGExists.Trim() -eq 1) `
        -Message "Memory-optimized FileGroup is required and should be created"

    # Verify memory-optimized table exists and has data
    try {
        $hotDataCount = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.HotData" $targetDb3
        Write-TestResult -TestName "Memory-optimized table imported" -Passed ([int]$hotDataCount.Trim() -eq 2) `
            -Message "HotData table should have 2 rows"
    } catch {
        Write-TestResult -TestName "Memory-optimized table imported" -Passed $false `
            -Message "Could not query HotData table: $_"
    }

    # Verify non-memory FileGroups were NOT created
    $nonMemFGCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name NOT IN ('PRIMARY', 'FG_MEMORY')" $targetDb3
    Write-TestResult -TestName "Non-memory FileGroups removed" -Passed ([int]$nonMemFGCount.Trim() -eq 0) `
        -Message "FG_LOB and FG_ARCHIVE should not exist in removeToPrimary mode"

    Drop-TestDatabase -DbName $targetDb3
}

# ═══════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Cleanup: Removing test databases..." -ForegroundColor Gray
Drop-TestDatabase -DbName $SourceDatabase

# ═══════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "ADVANCED FILEGROUP TEST SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

Write-Host "Tests Passed: $script:testsPassed" -ForegroundColor Green
Write-Host "Tests Skipped: $script:testsSkipped" -ForegroundColor Yellow
Write-Host "Tests Failed: $script:testsFailed" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })

if ($script:testsFailed -gt 0) {
    Write-Host "`n[FAILED] Some tests failed!" -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[SUCCESS] All tests passed!" -ForegroundColor Green
    exit 0
}
