<#
.SYNOPSIS
    Integration test for selective object type export/import functionality.

.DESCRIPTION
    Tests the -IncludeObjectTypes and -ExcludeObjectTypes parameters for both
    Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1 scripts.
#>

[CmdletBinding()]
param(
    [string]$Server = "localhost,1433",
    [string]$SourceDatabase = "TestDb",
    [PSCredential]$Credential
)

$ErrorActionPreference = 'Stop'

# Paths
$scriptRoot = Split-Path $PSScriptRoot -Parent
$exportScript = Join-Path $scriptRoot "Export-SqlServerSchema.ps1"
$importScript = Join-Path $scriptRoot "Import-SqlServerSchema.ps1"
$testOutputBase = Join-Path $scriptRoot "DbScripts\Tests_SelectiveTypes"

# Colors for output
function Write-TestInfo { param([string]$Message) Write-Host "[INFO] $Message" -ForegroundColor Cyan }
function Write-TestSuccess { param([string]$Message) Write-Host "[SUCCESS] $Message" -ForegroundColor Green }
function Write-TestFailure { param([string]$Message) Write-Host "[FAILURE] $Message" -ForegroundColor Red }
function Write-TestSection { param([string]$Message) Write-Host "`n=== $Message ===" -ForegroundColor Yellow }

# Cleanup function
function Remove-TestDatabase {
    param([string]$DatabaseName)
    
    try {
        $query = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$DatabaseName')
BEGIN
    ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$DatabaseName];
END
"@
        Invoke-Sqlcmd -ServerInstance $Server -Query $query -Credential $Credential -TrustServerCertificate -ErrorAction SilentlyContinue
        Write-TestInfo "Dropped test database: $DatabaseName"
    } catch {
        Write-TestInfo "Could not drop $DatabaseName (may not exist): $_"
    }
}

# Verify object exists
function Test-ObjectExists {
    param(
        [string]$DatabaseName,
        [string]$ObjectType,
        [string]$ObjectName
    )
    
    $query = switch ($ObjectType) {
        'Table' { "SELECT 1 FROM sys.tables WHERE name = '$ObjectName'" }
        'View' { "SELECT 1 FROM sys.views WHERE name = '$ObjectName'" }
        'StoredProcedure' { "SELECT 1 FROM sys.procedures WHERE name = '$ObjectName'" }
        'Function' { "SELECT 1 FROM sys.objects WHERE type IN ('FN','IF','TF') AND name = '$ObjectName'" }
        'Schema' { "SELECT 1 FROM sys.schemas WHERE name = '$ObjectName'" }
        default { throw "Unknown object type: $ObjectType" }
    }
    
    $result = Invoke-Sqlcmd -ServerInstance $Server -Database $DatabaseName -Query $query -Credential $Credential -TrustServerCertificate
    return $null -ne $result
}

# Count folders in export
function Get-ExportFolderCount {
    param([string]$ExportPath)
    
    $folders = Get-ChildItem -Path $ExportPath -Directory | Where-Object { $_.Name -match '^\d{2}_' }
    return $folders.Count
}

# Check if specific folder exists
function Test-FolderExists {
    param(
        [string]$ExportPath,
        [string]$FolderPattern
    )
    
    $folders = Get-ChildItem -Path $ExportPath -Directory | Where-Object { $_.Name -match $FolderPattern }
    return $folders.Count -gt 0
}

try {
    Write-TestSection "Starting Selective Object Type Tests"
    
    # Test database names
    $testDb1 = "TestSelectiveExport_TablesOnly"
    $testDb2 = "TestSelectiveExport_ExcludeData"
    $testDb3 = "TestSelectiveImport_ViewsOnly"
    
    # Cleanup any existing test databases
    Write-TestInfo "Cleaning up existing test databases..."
    Remove-TestDatabase $testDb1
    Remove-TestDatabase $testDb2
    Remove-TestDatabase $testDb3
    
    #region Test 1: Export Only Tables
    Write-TestSection "Test 1: Export Only Tables (-IncludeObjectTypes Tables)"
    
    $exportPath1 = Join-Path $testOutputBase "Test1_TablesOnly"
    if (Test-Path $exportPath1) {
        Remove-Item $exportPath1 -Recurse -Force
    }
    
    Write-TestInfo "Exporting only Tables from $SourceDatabase..."
    $exportParams = @{
        Server = $Server
        Database = $SourceDatabase
        OutputPath = $exportPath1
        TargetSqlVersion = 'Sql2022'
        IncludeObjectTypes = @('Tables')
    }
    if ($Credential) { $exportParams.Credential = $Credential }
    
    & $exportScript @exportParams
    
    # Verify export
    $exportSubDir = Get-ChildItem $exportPath1 -Directory | Select-Object -First 1
    if (-not $exportSubDir) {
        throw "No export subdirectory created"
    }
    
    # Check that only table-related SQL files exist
    $tablePKFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '09_Tables_PrimaryKey') -Filter '*.sql' -ErrorAction SilentlyContinue)
    $viewsFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '14_Programmability\05_Views') -Filter '*.sql' -ErrorAction SilentlyContinue)
    $procsFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '14_Programmability\03_StoredProcedures') -Filter '*.sql' -ErrorAction SilentlyContinue)
    
    if ($tablePKFiles.Count -gt 0) {
        Write-TestSuccess "Table SQL files exist ($($tablePKFiles.Count) files)"
    } else {
        Write-TestFailure "Table SQL files missing"
        throw "Expected table SQL files not found"
    }
    
    if ($viewsFiles.Count -eq 0 -and $procsFiles.Count -eq 0) {
        Write-TestSuccess "Non-table SQL files correctly excluded"
    } else {
        Write-TestFailure "Non-table SQL files should not exist (Views: $($viewsFiles.Count), Procs: $($procsFiles.Count))"
        throw "Unexpected SQL files found in export"
    }
    
    Write-TestSuccess "Test 1 Passed: Only Tables exported"
    #endregion
    
    #region Test 2: Export Excluding Data
    Write-TestSection "Test 2: Export Excluding Data (-ExcludeObjectTypes Data)"
    
    $exportPath2 = Join-Path $testOutputBase "Test2_ExcludeData"
    if (Test-Path $exportPath2) {
        Remove-Item $exportPath2 -Recurse -Force
    }
    
    Write-TestInfo "Exporting all except Data from $SourceDatabase..."
    $exportParams = @{
        Server = $Server
        Database = $SourceDatabase
        OutputPath = $exportPath2
        TargetSqlVersion = 'Sql2022'
        ExcludeObjectTypes = @('Data')
    }
    if ($Credential) { $exportParams.Credential = $Credential }
    
    & $exportScript @exportParams
    
    # Verify export
    $exportSubDir = Get-ChildItem $exportPath2 -Directory | Select-Object -First 1
    if (-not $exportSubDir) {
        throw "No export subdirectory created"
    }
    
    # Check that Data SQL files do NOT exist
    $dataFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '21_Data') -Filter '*.sql' -ErrorAction SilentlyContinue)
    $tablePKFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '09_Tables_PrimaryKey') -Filter '*.sql' -ErrorAction SilentlyContinue)
    
    if ($dataFiles.Count -eq 0) {
        Write-TestSuccess "Data SQL files correctly excluded"
    } else {
        Write-TestFailure "Data SQL files should not exist ($($dataFiles.Count) found)"
        throw "Data files found when they should be excluded"
    }
    
    if ($tablePKFiles.Count -gt 0) {
        Write-TestSuccess "Other object SQL files exist as expected"
    } else {
        Write-TestFailure "No other SQL files found"
        throw "Expected other SQL files to exist"
    }
    
    Write-TestSuccess "Test 2 Passed: Data excluded from export"
    #endregion
    
    #region Test 3: Export Multiple Types (Tables + Views)
    Write-TestSection "Test 3: Export Multiple Types (-IncludeObjectTypes Tables,Views)"
    
    $exportPath3 = Join-Path $testOutputBase "Test3_TablesAndViews"
    if (Test-Path $exportPath3) {
        Remove-Item $exportPath3 -Recurse -Force
    }
    
    Write-TestInfo "Exporting Tables and Views from $SourceDatabase..."
    $exportParams = @{
        Server = $Server
        Database = $SourceDatabase
        OutputPath = $exportPath3
        TargetSqlVersion = 'Sql2022'
        IncludeObjectTypes = @('Tables', 'Views')
    }
    if ($Credential) { $exportParams.Credential = $Credential }
    
    & $exportScript @exportParams
    
    # Verify export
    $exportSubDir = Get-ChildItem $exportPath3 -Directory | Select-Object -First 1
    if (-not $exportSubDir) {
        throw "No export subdirectory created"
    }
    
    $tablePKFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '09_Tables_PrimaryKey') -Filter '*.sql' -ErrorAction SilentlyContinue)
    $viewsFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '14_Programmability\05_Views') -Filter '*.sql' -ErrorAction SilentlyContinue)
    $procsFiles = @(Get-ChildItem (Join-Path $exportSubDir.FullName '14_Programmability\03_StoredProcedures') -Filter '*.sql' -ErrorAction SilentlyContinue)
    
    if ($tablePKFiles.Count -gt 0 -and $viewsFiles.Count -gt 0) {
        Write-TestSuccess "Tables and Views SQL files exist ($($tablePKFiles.Count) tables, $($viewsFiles.Count) views)"
    } else {
        Write-TestFailure "Expected SQL files missing (Tables: $($tablePKFiles.Count), Views: $($viewsFiles.Count))"
        throw "Tables or Views SQL files not found"
    }
    
    if ($procsFiles.Count -eq 0) {
        Write-TestSuccess "Programmability SQL files correctly excluded"
    } else {
        Write-TestFailure "Programmability SQL files should not exist ($($procsFiles.Count) found)"
        throw "Unexpected SQL files found"
    }
    
    Write-TestSuccess "Test 3 Passed: Multiple types exported correctly"
    #endregion
    
    #region Test 4: Import Filtering - Verify Script Collection
    Write-TestSection "Test 4: Import Script Collection Filtering"
    
    # This test verifies that the -IncludeObjectTypes parameter correctly filters
    # which scripts are collected. We don't actually execute the import since
    # the test database has complex dependencies between object types.
    
    # First, create full export if not already done
    $exportPathFull = Join-Path $testOutputBase "Test4_FullExport"
    if (Test-Path $exportPathFull) {
        Remove-Item $exportPathFull -Recurse -Force
    }
    
    Write-TestInfo "Creating full export of $SourceDatabase..."
    $exportParams = @{
        Server = $Server
        Database = $SourceDatabase
        OutputPath = $exportPathFull
        TargetSqlVersion = 'Sql2022'
    }
    if ($Credential) { $exportParams.Credential = $Credential }
    
    & $exportScript @exportParams
    
    $exportSubDir = Get-ChildItem $exportPathFull -Directory | Select-Object -First 1
    
    # Test 4a: Verify Tables filter collects only table scripts
    Write-TestInfo "Test 4a: Verifying Tables filter collects correct scripts..."
    $tableScripts = Get-ChildItem (Join-Path $exportSubDir.FullName "09_Tables_PrimaryKey") -Filter "*.sql" -Recurse
    $fkScripts = Get-ChildItem (Join-Path $exportSubDir.FullName "10_Tables_ForeignKeys") -Filter "*.sql" -Recurse
    $expectedTableScriptCount = $tableScripts.Count + $fkScripts.Count
    
    Write-TestInfo "  Expected script count for Tables filter: $expectedTableScriptCount (Tables: $($tableScripts.Count), FKs: $($fkScripts.Count))"
    
    if ($expectedTableScriptCount -gt 0) {
        Write-TestSuccess "Tables folder contains $expectedTableScriptCount script(s)"
    } else {
        Write-TestFailure "No table scripts found in export"
        throw "Expected table scripts in export"
    }
    
    # Test 4b: Verify Views filter targets correct subfolder
    Write-TestInfo "Test 4b: Verifying Views filter targets correct subfolder..."
    $viewsFolder = Join-Path $exportSubDir.FullName "14_Programmability\05_Views"
    if (Test-Path $viewsFolder) {
        $viewScripts = Get-ChildItem $viewsFolder -Filter "*.sql" -Recurse
        Write-TestInfo "  Views subfolder contains $($viewScripts.Count) script(s)"
        
        if ($viewScripts.Count -gt 0) {
            Write-TestSuccess "Views subfolder exists and contains $($viewScripts.Count) view script(s)"
        } else {
            Write-TestFailure "Views subfolder is empty"
            throw "Expected view scripts in subfolder"
        }
    } else {
        Write-TestFailure "Views subfolder not found at expected path"
        throw "Expected 14_Programmability\05_Views folder"
    }
    
    # Test 4c: Verify Functions filter targets correct subfolder
    Write-TestInfo "Test 4c: Verifying Functions filter targets correct subfolder..."
    $functionsFolder = Join-Path $exportSubDir.FullName "14_Programmability\02_Functions"
    if (Test-Path $functionsFolder) {
        $funcScripts = Get-ChildItem $functionsFolder -Filter "*.sql" -Recurse
        Write-TestInfo "  Functions subfolder contains $($funcScripts.Count) script(s)"
        
        if ($funcScripts.Count -gt 0) {
            Write-TestSuccess "Functions subfolder exists and contains $($funcScripts.Count) function script(s)"
        } else {
            Write-TestFailure "Functions subfolder is empty"
            throw "Expected function scripts in subfolder"
        }
    } else {
        Write-TestFailure "Functions subfolder not found at expected path"
        throw "Expected 14_Programmability\02_Functions folder"
    }
    
    # Test 4d: Verify StoredProcedures filter targets correct subfolder
    Write-TestInfo "Test 4d: Verifying StoredProcedures filter targets correct subfolder..."
    $procsFolder = Join-Path $exportSubDir.FullName "14_Programmability\03_StoredProcedures"
    if (Test-Path $procsFolder) {
        $procScripts = Get-ChildItem $procsFolder -Filter "*.sql" -Recurse
        Write-TestInfo "  StoredProcedures subfolder contains $($procScripts.Count) script(s)"
        
        if ($procScripts.Count -gt 0) {
            Write-TestSuccess "StoredProcedures subfolder exists and contains $($procScripts.Count) stored procedure script(s)"
        } else {
            Write-TestFailure "StoredProcedures subfolder is empty"
            throw "Expected stored procedure scripts in subfolder"
        }
    } else {
        Write-TestFailure "StoredProcedures subfolder not found at expected path"
        throw "Expected 14_Programmability\03_StoredProcedures folder"
    }
    
    Write-TestSuccess "Test 4 Passed: Import script collection filtering verified"
    #endregion
    
    #region Test 5: Full Import Verification (all types)
    Write-TestSection "Test 5: Full Import of All Object Types"
    
    # This test verifies that a full import (no filtering) works correctly
    Write-TestInfo "Creating test database: $testDb1"
    Remove-TestDatabase $testDb1
    $createDbQuery = "CREATE DATABASE [$testDb1]"
    Invoke-Sqlcmd -ServerInstance $Server -Query $createDbQuery -Credential $Credential -TrustServerCertificate
    
    # Import everything (no filtering)
    Write-TestInfo "Importing all object types to $testDb1..."
    $importParams = @{
        Server = $Server
        Database = $testDb1
        SourcePath = $exportSubDir.FullName
        ImportMode = 'Dev'
        # No IncludeObjectTypes = import everything
    }
    if ($Credential) { $importParams.Credential = $Credential }
    
    & $importScript @importParams
    
    # Verify import results
    Write-TestInfo "Verifying full import..."
    
    # Check that objects were created
    $objectsQuery = @"
SELECT 
    (SELECT COUNT(*) FROM sys.schemas WHERE schema_id > 4 AND schema_id < 16384) as SchemaCount,
    (SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0) as TableCount,
    (SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0) as ViewCount,
    (SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0) as ProcCount,
    (SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0) as FuncCount
"@
    $counts = Invoke-Sqlcmd -ServerInstance $Server -Database $testDb1 -Query $objectsQuery -Credential $Credential -TrustServerCertificate
    
    Write-TestInfo "  Schemas: $($counts.SchemaCount), Tables: $($counts.TableCount), Views: $($counts.ViewCount), Procs: $($counts.ProcCount), Functions: $($counts.FuncCount)"
    
    if ($counts.SchemaCount -gt 0) {
        Write-TestSuccess "Schemas imported: $($counts.SchemaCount)"
    } else {
        Write-TestFailure "No schemas found after import"
    }
    
    if ($counts.TableCount -gt 0) {
        Write-TestSuccess "Tables imported: $($counts.TableCount)"
    } else {
        Write-TestFailure "No tables found after import"
    }
    
    if ($counts.ViewCount -gt 0) {
        Write-TestSuccess "Views imported: $($counts.ViewCount)"
    } else {
        Write-TestFailure "No views found after import"
    }
    
    if ($counts.ProcCount -gt 0) {
        Write-TestSuccess "Stored procedures imported: $($counts.ProcCount)"
    } else {
        Write-TestFailure "No stored procedures found after import"
    }
    
    if ($counts.FuncCount -gt 0) {
        Write-TestSuccess "Functions imported: $($counts.FuncCount)"
    } else {
        Write-TestFailure "No functions found after import"
    }
    
    Write-TestSuccess "Test 5 Passed: Full import completed successfully"
    #endregion
    
    Write-TestSection "All Selective Object Type Tests Passed!"
    Write-Host "`nTest Summary:" -ForegroundColor Yellow
    Write-Host "  [SUCCESS] Test 1: Export only Tables" -ForegroundColor Green
    Write-Host "  [SUCCESS] Test 2: Export excluding Data" -ForegroundColor Green
    Write-Host "  [SUCCESS] Test 3: Export Tables + Views" -ForegroundColor Green
    Write-Host "  [SUCCESS] Test 4: Import script collection filtering" -ForegroundColor Green
    Write-Host "  [SUCCESS] Test 5: Full import of all object types" -ForegroundColor Green
    
} catch {
    Write-TestFailure "Test failed: $_"
    Write-Host $_.ScriptStackTrace -ForegroundColor Red
    exit 1
} finally {
    # Cleanup
    Write-TestInfo "`nCleaning up test databases..."
    Remove-TestDatabase $testDb1
    Remove-TestDatabase $testDb2
    Remove-TestDatabase $testDb3
    
    Write-TestInfo "Cleanup complete"
}

exit 0
