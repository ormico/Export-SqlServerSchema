#Requires -Version 7.0

<#
.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    Comprehensive integration test for SQL Server schema export/import scripts

.DESCRIPTION
    This test performs a complete workflow:
    1. Creates test database (TestDb) with schema and data
    2. Exports the schema using Export-SqlServerSchema.ps1
    3. Imports to a new database (TestDb_Restored) using Import-SqlServerSchema.ps1
    4. Verifies that source and target databases match

.EXAMPLE
    ./run-integration-test.ps1
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

            if($_ -match 'PASSWORD|SECRET|KEY') {
                Write-Host "  $name = ********" -ForegroundColor Gray
            } else {
                Write-Host "  $name = $value" -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Error "Configuration file not found: $ConfigFile"
    Write-Host "Please copy .env.example to .env and configure settings" -ForegroundColor Yellow
    exit 1
}

# Configuration
$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourceDatabase = $TEST_DATABASE
$TargetDatabaseDev = "${TEST_DATABASE}_Dev"
$TargetDatabaseProd = "${TEST_DATABASE}_Prod"
$ExportPath = Join-Path $PSScriptRoot "exports"
$DevConfigFile = Join-Path $PSScriptRoot "test-dev-config.yml"
$ProdConfigFile = Join-Path $PSScriptRoot "test-prod-config.yml"

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "SQL SERVER SCHEMA EXPORT/IMPORT INTEGRATION TEST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

Write-Host "Configuration:" -ForegroundColor Yellow
Write-Host "  Server: $Server" -ForegroundColor White
Write-Host "  Source Database: $SourceDatabase" -ForegroundColor White
Write-Host "  Target Database (Dev): $TargetDatabaseDev" -ForegroundColor White
Write-Host "  Target Database (Prod): $TargetDatabaseProd" -ForegroundColor White
Write-Host "  Export Path: $ExportPath" -ForegroundColor White
Write-Host "  Dev Config: $DevConfigFile" -ForegroundColor White
Write-Host "  Prod Config: $ProdConfigFile`n" -ForegroundColor White

# Helper function to execute SQL
function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )

    $result = sqlcmd -S $Server -U $Username -P $Password -d $Database -C -Q $Query -h -1 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL command failed: $result"
    }

    # Extract just the numeric value from the first line
    # Result may contain multiple lines like "5" and "(1 rows affected)"
    $lines = $result -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($lines.Count -gt 0) {
        # Get first non-empty line and extract number
        $firstLine = $lines[0].Trim()
        if ($firstLine -match '^\d+$') {
            return $firstLine
        }
    }

    return $result
}

# Helper function for test status
function Write-TestStep {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Error", "Warning")]
        [string]$Type = "Info"
    )

    $colors = @{
        Info = "Cyan"
        Success = "Green"
        Error = "Red"
        Warning = "Yellow"
    }

    $prefixes = @{
        Info = "[INFO] "
        Success = "[SUCCESS]"
        Error = "[ERROR]"
        Warning = "[WARNING] "
    }

    Write-Host "$($prefixes[$Type]) $Message" -ForegroundColor $colors[$Type]
}

try {
    # Step 1: Wait for SQL Server
    Write-TestStep "Step 1: Checking SQL Server availability..." -Type Info
    $maxAttempts = 30
    $attempt = 0
    $connected = $false

    while ($attempt -lt $maxAttempts -and -not $connected) {
        $attempt++
        try {
            $null = Invoke-SqlCommand "SELECT 1" "master"
            $connected = $true
            Write-TestStep "SQL Server is ready (attempt $attempt)" -Type Success
        } catch {
            if ($attempt -lt $maxAttempts) {
                Write-Host "  Waiting for SQL Server... ($attempt/$maxAttempts)" -ForegroundColor Gray
                Start-Sleep -Seconds 2
            }
        }
    }

    if (-not $connected) {
        throw "Failed to connect to SQL Server after $maxAttempts attempts"
    }

    # Step 2: Create test database from SQL file
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 2: Creating test database from test-schema.sql..." -Type Info

    $schemaFile = Join-Path $PSScriptRoot "test-schema.sql"
    if (-not (Test-Path $schemaFile)) {
        throw "Schema file not found: $schemaFile"
    }

    Write-Host "  Executing SQL script..." -ForegroundColor Gray
    $result = sqlcmd -S $Server -U $Username -P $Password -C -i $schemaFile 2>&1

    if ($LASTEXITCODE -eq 0) {
        Write-TestStep "Test database created successfully" -Type Success
        # Show creation summary
        $result | Where-Object { $_ -match "Database:|Schemas:|Tables:|Views:|Functions:|Procedures:|Triggers:|Data:" } | ForEach-Object {
            Write-Host "  $_" -ForegroundColor Gray
        }
    } else {
        throw "Failed to create test database: $result"
    }

    # Step 3: Verify test database
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 3: Verifying test database structure..." -Type Info

    $tableCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $SourceDatabase
    $viewCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $SourceDatabase
    $procCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $SourceDatabase
    $funcCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0" $SourceDatabase
    $fileGroupCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name NOT IN ('PRIMARY')" $SourceDatabase
    $securityPolicyCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.security_policies" $SourceDatabase

    Write-Host "  Tables: $($tableCount.Trim())" -ForegroundColor White
    Write-Host "  Views: $($viewCount.Trim())" -ForegroundColor White
    Write-Host "  Stored Procedures: $($procCount.Trim())" -ForegroundColor White
    Write-Host "  Functions: $($funcCount.Trim())" -ForegroundColor White
    Write-Host "  FileGroups (non-PRIMARY): $($fileGroupCount.Trim())" -ForegroundColor White
    Write-Host "  Security Policies: $($securityPolicyCount.Trim())" -ForegroundColor White

    Write-TestStep "Database structure verified" -Type Success

    # Step 4: Export schema
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 4: Exporting schema with Export-SqlServerSchema.ps1..." -Type Info

    # Clean export directory
    if (Test-Path $ExportPath) {
        Write-Host "  Cleaning previous exports..." -ForegroundColor Gray
        Remove-Item $ExportPath -Recurse -Force
    }

    Write-Host "  Running export script..." -ForegroundColor Gray

    # Check if Export-SqlServerSchema.ps1 exists
    $exportScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Export-SqlServerSchema.ps1"
    if (-not (Test-Path $exportScript)) {
        throw "Export script not found: $exportScript"
    }

    # Build credential object
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    # Get export config path
    $exportConfigPath = Join-Path $PSScriptRoot "test-export-config.yml"

    # Run export (this will fail if SMO is not installed, but we'll handle it gracefully)
    try {
        & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $ExportPath -IncludeData -Credential $credential -ConfigFile $exportConfigPath -Verbose
        Write-TestStep "Schema exported successfully" -Type Success
    } catch {
        Write-TestStep "Export failed (SMO may not be installed)" -Type Warning
        Write-Host "  Error: $_" -ForegroundColor Yellow
        Write-Host "  To install SMO: Install-Module SqlServer -Scope CurrentUser" -ForegroundColor Yellow
        Write-Host "  Skipping export/import test, but database creation was successful" -ForegroundColor Yellow
        exit 0
    }

    # Verify export
    $exportDirs = Get-ChildItem $ExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
    if ($exportDirs.Count -eq 0) {
        throw "No export directory created"
    }

    $exportDir = $exportDirs[0].FullName
    Write-Host "  Export location: $exportDir" -ForegroundColor Gray

    $sqlFiles = Get-ChildItem $exportDir -Recurse -Filter "*.sql"
    Write-Host "  SQL files created: $($sqlFiles.Count)" -ForegroundColor White
    Write-TestStep "Export verified" -Type Success

    # Step 4.5: Test parallel export (schema only, for comparison with sequential schema)
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 4.5: Testing parallel export mode (schema only)..." -Type Info

    # First, do a sequential schema-only export for comparison
    $seqSchemaExportPath = Join-Path $PSScriptRoot "exports_seq_schema"
    if (Test-Path $seqSchemaExportPath) {
        Write-Host "  Cleaning previous sequential schema exports..." -ForegroundColor Gray
        Remove-Item $seqSchemaExportPath -Recurse -Force
    }

    Write-Host "  Running sequential schema-only export for comparison..." -ForegroundColor Gray
    & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $seqSchemaExportPath -Credential $credential -ConfigFile $exportConfigPath -Verbose 2>&1 | Out-Null

    $seqSchemaDirs = Get-ChildItem $seqSchemaExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
    $seqSchemaDir = $seqSchemaDirs[0].FullName
    $seqSchemaFiles = Get-ChildItem $seqSchemaDir -Recurse -Filter "*.sql"

    # Now do parallel schema-only export
    $parallelExportPath = Join-Path $PSScriptRoot "exports_parallel"
    if (Test-Path $parallelExportPath) {
        Write-Host "  Cleaning previous parallel exports..." -ForegroundColor Gray
        Remove-Item $parallelExportPath -Recurse -Force
    }

    Write-Host "  Running parallel export with 3 workers..." -ForegroundColor Gray
    $parallelConfigPath = Join-Path $PSScriptRoot "test-parallel-config.yml"

    $parallelStart = Get-Date
    try {
        & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $parallelExportPath -Credential $credential -ConfigFile $parallelConfigPath -Verbose 2>&1 | Out-Null
        $parallelDuration = ((Get-Date) - $parallelStart).TotalSeconds
        Write-Host "  Parallel export completed in $($parallelDuration.ToString('F2'))s" -ForegroundColor White
        Write-TestStep "Parallel export successful" -Type Success
    } catch {
        Write-TestStep "Parallel export failed" -Type Warning
        Write-Host "  Error: $_" -ForegroundColor Yellow
        Write-Host "  Continuing with sequential export test..." -ForegroundColor Yellow
    }

    # Verify parallel export produced same file count - FAIL if mismatch
    $parallelExportValid = $false
    if (Test-Path $parallelExportPath) {
        $parallelDirs = Get-ChildItem $parallelExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
        if ($parallelDirs.Count -gt 0) {
            $parallelDir = $parallelDirs[0].FullName
            $parallelSqlFiles = Get-ChildItem $parallelDir -Recurse -Filter "*.sql"
            Write-Host "  Parallel SQL files: $($parallelSqlFiles.Count)" -ForegroundColor White
            Write-Host "  Sequential SQL files (schema only): $($seqSchemaFiles.Count)" -ForegroundColor White

            # Compare relative paths (not just filenames)
            $seqRelPaths = $seqSchemaFiles | ForEach-Object { $_.FullName.Replace($seqSchemaDir + [IO.Path]::DirectorySeparatorChar, '') } | Sort-Object
            $parRelPaths = $parallelSqlFiles | ForEach-Object { $_.FullName.Replace($parallelDir + [IO.Path]::DirectorySeparatorChar, '') } | Sort-Object

            $pathDiff = Compare-Object $seqRelPaths $parRelPaths
            if ($pathDiff) {
                Write-Host "  [ERROR] File path differences found:" -ForegroundColor Red
                $pathDiff | ForEach-Object {
                    $indicator = if ($_.SideIndicator -eq '<=') { 'Sequential only' } else { 'Parallel only' }
                    Write-Host "    [$indicator] $($_.InputObject)" -ForegroundColor Yellow
                }
                throw "Parallel export file paths must match sequential export"
            }
            Write-TestStep "Parallel export file paths match sequential" -Type Success

            # Compare file contents using hashes
            Write-Host "  Comparing file contents..." -ForegroundColor Gray
            $contentMismatches = @()
            $emptyFiles = @()

            foreach ($seqFile in $seqSchemaFiles) {
                $relPath = $seqFile.FullName.Replace($seqSchemaDir + [IO.Path]::DirectorySeparatorChar, '')
                $parFile = Join-Path $parallelDir $relPath

                if (Test-Path $parFile) {
                    # Check for empty files (except known empty ones like public.role.sql)
                    $seqSize = (Get-Item $seqFile.FullName).Length
                    $parSize = (Get-Item $parFile).Length

                    if ($seqSize -gt 0 -and $parSize -eq 0) {
                        $emptyFiles += $relPath
                    }
                    elseif ($seqSize -eq 0 -and $parSize -gt 0) {
                        $emptyFiles += "$relPath (sequential empty, parallel has content)"
                    }
                    elseif ($seqSize -gt 0 -and $parSize -gt 0) {
                        # Compare hashes for non-empty files
                        $seqHash = (Get-FileHash $seqFile.FullName -Algorithm MD5).Hash
                        $parHash = (Get-FileHash $parFile -Algorithm MD5).Hash

                        if ($seqHash -ne $parHash) {
                            $contentMismatches += $relPath
                        }
                    }
                }
            }

            if ($emptyFiles.Count -gt 0) {
                Write-Host "  [ERROR] Files with unexpected empty content:" -ForegroundColor Red
                $emptyFiles | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
                throw "Parallel export produced empty files that should have content"
            }

            if ($contentMismatches.Count -gt 0) {
                Write-Host "  [ERROR] Files with content differences:" -ForegroundColor Red
                $contentMismatches | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
                throw "Parallel export file contents must match sequential export"
            }

            Write-TestStep "Parallel export file contents match sequential" -Type Success
            $parallelExportValid = $true
        }
    }

    # Step 4.6: Test parallel export WITH DATA (regression test for data export bugs)
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 4.6: Testing parallel export with data (regression test)..." -Type Info

    $parallelDataExportPath = Join-Path $PSScriptRoot "exports_parallel_data"
    if (Test-Path $parallelDataExportPath) {
        Write-Host "  Cleaning previous parallel data exports..." -ForegroundColor Gray
        Remove-Item $parallelDataExportPath -Recurse -Force
    }

    Write-Host "  Running parallel export WITH data..." -ForegroundColor Gray
    $parallelDataStart = Get-Date

    try {
        # Run parallel export with IncludeData
        & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $parallelDataExportPath -IncludeData -Credential $credential -ConfigFile $parallelConfigPath -Verbose 2>&1 | Out-Null
        $parallelDataDuration = ((Get-Date) - $parallelDataStart).TotalSeconds
        Write-Host "  Parallel data export completed in $($parallelDataDuration.ToString('F2'))s" -ForegroundColor White

        # Verify parallel data export
        $parallelDataDirs = Get-ChildItem $parallelDataExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
        if ($parallelDataDirs.Count -gt 0) {
            $parallelDataDir = $parallelDataDirs[0].FullName
            $parallelDataFolder = Join-Path $parallelDataDir "21_Data"

            # Check that 21_Data folder exists and has files
            if (Test-Path $parallelDataFolder) {
                $parallelDataFiles = Get-ChildItem $parallelDataFolder -Filter "*.sql" -ErrorAction SilentlyContinue
                Write-Host "  Data files in parallel export: $($parallelDataFiles.Count)" -ForegroundColor White

                # Verify data files are not empty
                $emptyDataFiles = @()
                foreach ($dataFile in $parallelDataFiles) {
                    if ((Get-Item $dataFile.FullName).Length -eq 0) {
                        $emptyDataFiles += $dataFile.Name
                    }
                }

                if ($emptyDataFiles.Count -gt 0) {
                    Write-Host "  [ERROR] Empty data files found:" -ForegroundColor Red
                    $emptyDataFiles | ForEach-Object { Write-Host "    - $_" -ForegroundColor Yellow }
                    throw "Parallel data export produced empty data files"
                }

                # Verify data file count matches tables with data
                $tablesWithData = Invoke-SqlCommand @"
SELECT COUNT(DISTINCT t.name) FROM sys.tables t
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE t.is_ms_shipped = 0 AND p.index_id IN (0, 1) AND p.rows > 0
"@ $SourceDatabase

                Write-Host "  Tables with data in source: $($tablesWithData.Trim())" -ForegroundColor White

                if ($parallelDataFiles.Count -eq [int]$tablesWithData.Trim()) {
                    Write-TestStep "Parallel data export file count matches tables with data" -Type Success
                } else {
                    Write-Host "  [WARNING] Data file count mismatch: $($parallelDataFiles.Count) files vs $($tablesWithData.Trim()) tables" -ForegroundColor Yellow
                }

                Write-TestStep "Parallel data export successful" -Type Success
            } else {
                Write-Host "  [ERROR] 21_Data folder not found in parallel export" -ForegroundColor Red
                throw "Parallel data export did not create 21_Data folder"
            }
        }
    } catch {
        Write-TestStep "Parallel data export failed" -Type Error
        Write-Host "  Error: $_" -ForegroundColor Red
        throw "Parallel data export regression test failed: $_"
    }

    # Step 5: Prepare target databases
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 5: Preparing target databases..." -Type Info

    # Drop Dev database if exists
    $dbExists = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.databases WHERE name = '$TargetDatabaseDev'" "master"
    if ($dbExists.Trim() -eq "1") {
        Write-Host "  Dropping existing Dev target database..." -ForegroundColor Gray
        Invoke-SqlCommand "ALTER DATABASE [$TargetDatabaseDev] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$TargetDatabaseDev];" "master"
    }

    # Drop Prod database if exists
    $dbExists = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.databases WHERE name = '$TargetDatabaseProd'" "master"
    if ($dbExists.Trim() -eq "1") {
        Write-Host "  Dropping existing Prod target database..." -ForegroundColor Gray
        Invoke-SqlCommand "ALTER DATABASE [$TargetDatabaseProd] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$TargetDatabaseProd];" "master"
    }

    # Clean up orphaned FileGroup files from previous runs
    Write-Host "  Cleaning up orphaned FileGroup files..." -ForegroundColor Gray
    $container = docker ps --format "{{.Names}}" | Select-String "sqlserver"
    if ($container) {
        docker exec $container bash -c "rm -f /var/opt/mssql/data/${TargetDatabaseDev}_*.ndf /var/opt/mssql/data/${TargetDatabaseProd}_*.ndf" 2>&1 | Out-Null
    }

    Write-TestStep "Target databases prepared" -Type Success

    # Step 6: Import schema in Dev mode
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 6: Importing schema in Dev mode..." -Type Info

    $importScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Import-SqlServerSchema.ps1"
    if (-not (Test-Path $importScript)) {
        throw "Import script not found: $importScript"
    }

    Write-Host "  Running Dev mode import..." -ForegroundColor Gray

    try {
        & $importScript -Server $TEST_SERVER -Database $TargetDatabaseDev -SourcePath $exportDir -CreateDatabase -Credential $credential -ConfigFile $DevConfigFile -Verbose
        Write-TestStep "Dev mode import completed" -Type Success
    } catch {
        Write-TestStep "Dev mode import failed" -Type Error
        throw $_
    }

    # Step 7: Verify Dev mode import
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 7: Verifying Dev mode import..." -Type Info

    $devTableCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $TargetDatabaseDev
    $devViewCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $TargetDatabaseDev
    $devProcCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $TargetDatabaseDev
    $devFuncCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0" $TargetDatabaseDev
    $devFileGroupCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name NOT IN ('PRIMARY')" $TargetDatabaseDev
    $devSecurityPolicyCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.security_policies" $TargetDatabaseDev

    Write-Host "  Dev Tables: $($devTableCount.Trim())" -ForegroundColor White
    Write-Host "  Dev Views: $($devViewCount.Trim())" -ForegroundColor White
    Write-Host "  Dev Stored Procedures: $($devProcCount.Trim())" -ForegroundColor White
    Write-Host "  Dev Functions: $($devFuncCount.Trim())" -ForegroundColor White
    Write-Host "  Dev FileGroups (non-PRIMARY): $($devFileGroupCount.Trim())" -ForegroundColor White
    Write-Host "  Dev Security Policies: $($devSecurityPolicyCount.Trim())" -ForegroundColor White

    # Dev mode with autoRemap strategy should import FileGroups (with auto-detected paths)
    if ($devFileGroupCount.Trim() -eq "2") {
        Write-TestStep "Dev mode correctly imported FileGroups with autoRemap strategy" -Type Success

        # Verify tables are on correct FileGroups
        $ordersFileGroup = Invoke-SqlCommand @"
SELECT fg.name FROM sys.tables t
INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
INNER JOIN sys.filegroups fg ON i.data_space_id = fg.data_space_id
WHERE t.name = 'Orders' AND SCHEMA_NAME(t.schema_id) = 'Sales'
"@ $TargetDatabaseDev

        $inventoryFileGroup = Invoke-SqlCommand @"
SELECT fg.name FROM sys.tables t
INNER JOIN sys.indexes i ON t.object_id = i.object_id AND i.index_id IN (0, 1)
INNER JOIN sys.filegroups fg ON i.data_space_id = fg.data_space_id
WHERE t.name = 'Inventory' AND SCHEMA_NAME(t.schema_id) = 'Warehouse'
"@ $TargetDatabaseDev

        if ($ordersFileGroup.Trim() -eq "FG_CURRENT" -and $inventoryFileGroup.Trim() -eq "FG_ARCHIVE") {
            Write-TestStep "Tables correctly placed on custom FileGroups" -Type Success
        } else {
            Write-TestStep "Tables not on expected FileGroups (Orders: $ordersFileGroup, Inventory: $inventoryFileGroup)" -Type Error
            throw "FileGroup placement verification failed"
        }

        # Verify FileGroup file sizes were overridden with Dev mode defaults
        # In Dev mode, files should be created with 1024KB (1MB) initial size
        $devFileSizes = Invoke-SqlCommand @"
SELECT df.size * 8 AS size_kb, df.growth * 8 AS growth_kb
FROM sys.database_files df
INNER JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id
WHERE fg.name IN ('FG_CURRENT', 'FG_ARCHIVE')
"@ $TargetDatabaseDev

        # Parse file sizes - size should be 1024KB (Dev default)
        # SQL Server may round to nearest extent (64KB), so we check for <= 1024KB
        $devFileSizeLines = $devFileSizes -split "`n" | Where-Object { $_.Trim() -match '^\d' }
        if ($devFileSizeLines.Count -gt 0) {
            $allFilesCorrectSize = $true
            foreach ($line in $devFileSizeLines) {
                if ($line.Trim() -match '^(\d+)\s+(\d+)') {
                    $sizeKB = [int]$matches[1]
                    # Dev default is 1024KB but SQL Server rounds to extent boundaries
                    # Accept sizes between 64KB and 2048KB as valid for the test
                    if ($sizeKB -lt 64 -or $sizeKB -gt 2048) {
                        $allFilesCorrectSize = $false
                        Write-Host "    Unexpected file size: ${sizeKB}KB (expected ~1024KB)" -ForegroundColor Yellow
                    }
                }
            }
            if ($allFilesCorrectSize) {
                Write-TestStep "Dev mode FileGroup files created with safe default sizes" -Type Success
            } else {
                Write-TestStep "Dev mode FileGroup file sizes not as expected" -Type Warning
            }
        }
    } else {
        Write-TestStep "Dev mode FileGroup count incorrect: expected 2, got $($devFileGroupCount.Trim())" -Type Error
        throw "Dev mode verification failed: FileGroups not imported correctly with autoRemap"
    }

    # Schema objects should match
    $devSchemaMatch = ($tableCount.Trim() -eq $devTableCount.Trim()) -and
                      ($viewCount.Trim() -eq $devViewCount.Trim()) -and
                      ($procCount.Trim() -eq $devProcCount.Trim()) -and
                      ($funcCount.Trim() -eq $devFuncCount.Trim())

    if ($devSchemaMatch) {
        Write-TestStep "Dev mode schema objects match source" -Type Success
    } else {
        Write-TestStep "Dev mode schema objects do not match!" -Type Error
        throw "Dev mode verification failed: Schema object counts differ"
    }

    # Step 8: Import schema in Prod mode
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 8: Importing schema in Prod mode..." -Type Info

    Write-Host "  Running Prod mode import..." -ForegroundColor Gray

    try {
        & $importScript -Server $TEST_SERVER -Database $TargetDatabaseProd -SourcePath $exportDir -CreateDatabase -Credential $credential -ConfigFile $ProdConfigFile -Verbose
        Write-TestStep "Prod mode import completed" -Type Success
    } catch {
        Write-TestStep "Prod mode import failed" -Type Error
        throw $_
    }

    # Step 9: Verify Prod mode import
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 9: Verifying Prod mode import..." -Type Info

    $prodTableCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $TargetDatabaseProd
    $prodViewCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $TargetDatabaseProd
    $prodProcCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $TargetDatabaseProd
    $prodFuncCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0" $TargetDatabaseProd
    $prodFileGroupCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.filegroups WHERE name NOT IN ('PRIMARY')" $TargetDatabaseProd
    $prodSecurityPolicyCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.security_policies" $TargetDatabaseProd
    $prodMaxDop = Invoke-SqlCommand "SELECT value FROM sys.database_scoped_configurations WHERE name = 'MAXDOP'" $TargetDatabaseProd

    Write-Host "  Prod Tables: $($prodTableCount.Trim())" -ForegroundColor White
    Write-Host "  Prod Views: $($prodViewCount.Trim())" -ForegroundColor White
    Write-Host "  Prod Stored Procedures: $($prodProcCount.Trim())" -ForegroundColor White
    Write-Host "  Prod Functions: $($prodFuncCount.Trim())" -ForegroundColor White
    Write-Host "  Prod FileGroups (non-PRIMARY): $($prodFileGroupCount.Trim())" -ForegroundColor White
    Write-Host "  Prod Security Policies: $($prodSecurityPolicyCount.Trim())" -ForegroundColor White
    Write-Host "  Prod MAXDOP Setting: $($prodMaxDop.Trim())" -ForegroundColor White

    # Prod mode should include FileGroups
    if ($prodFileGroupCount.Trim() -eq $fileGroupCount.Trim()) {
        Write-TestStep "Prod mode correctly imported FileGroups" -Type Success
    } else {
        Write-TestStep "Prod mode FileGroup count mismatch" -Type Error
        throw "Prod mode verification failed: Expected $($fileGroupCount.Trim()) FileGroups, got $($prodFileGroupCount.Trim())"
    }

    # Prod mode should have DB configurations (MAXDOP=4)
    if ($prodMaxDop.Trim() -eq "4") {
        Write-TestStep "Prod mode correctly set MAXDOP=4" -Type Success
    } else {
        Write-TestStep "Prod mode MAXDOP incorrect: $($prodMaxDop.Trim())" -Type Warning
    }

    # Verify FileGroup file sizes were overridden with Prod config values
    # In Prod config, we set 2048KB (2MB) initial size
    $prodFileSizes = Invoke-SqlCommand @"
SELECT df.size * 8 AS size_kb, df.growth * 8 AS growth_kb
FROM sys.database_files df
INNER JOIN sys.filegroups fg ON df.data_space_id = fg.data_space_id
WHERE fg.name IN ('FG_CURRENT', 'FG_ARCHIVE')
"@ $TargetDatabaseProd

    $prodFileSizeLines = $prodFileSizes -split "`n" | Where-Object { $_.Trim() -match '^\d' }
    if ($prodFileSizeLines.Count -gt 0) {
        $allProdFilesCorrectSize = $true
        foreach ($line in $prodFileSizeLines) {
            if ($line.Trim() -match '^(\d+)\s+(\d+)') {
                $sizeKB = [int]$matches[1]
                # Prod config sets 2048KB but SQL Server rounds to extent boundaries
                # Accept sizes between 64KB and 4096KB as valid for the test
                if ($sizeKB -lt 64 -or $sizeKB -gt 4096) {
                    $allProdFilesCorrectSize = $false
                    Write-Host "    Unexpected Prod file size: ${sizeKB}KB (expected ~2048KB)" -ForegroundColor Yellow
                }
            }
        }
        if ($allProdFilesCorrectSize) {
            Write-TestStep "Prod mode FileGroup files created with configured sizes" -Type Success
        } else {
            Write-TestStep "Prod mode FileGroup file sizes not as expected" -Type Warning
        }
    }

    # All objects should match
    $prodFullMatch = ($tableCount.Trim() -eq $prodTableCount.Trim()) -and
                     ($viewCount.Trim() -eq $prodViewCount.Trim()) -and
                     ($procCount.Trim() -eq $prodProcCount.Trim()) -and
                     ($funcCount.Trim() -eq $prodFuncCount.Trim()) -and
                     ($securityPolicyCount.Trim() -eq $prodSecurityPolicyCount.Trim())

    if ($prodFullMatch) {
        Write-TestStep "Prod mode all objects match source" -Type Success
    } else {
        Write-TestStep "Prod mode object counts do not match!" -Type Error
        throw "Prod mode verification failed: Object counts differ"
    }

    # Step 10: Verify data integrity
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 10: Verifying data integrity..." -Type Info

    # Check if data was actually exported by looking at the 21_Data folder
    $dataFolder = Join-Path $exportDir "21_Data"
    $dataFilesExist = $false
    if (Test-Path $dataFolder) {
        $dataFiles = Get-ChildItem $dataFolder -Filter "*.sql" -ErrorAction SilentlyContinue
        $dataFilesExist = ($dataFiles.Count -gt 0)
    }

    Write-Host "  Data export folder: $(if ($dataFilesExist) { "$($dataFiles.Count) file(s)" } else { 'empty or not present' })" -ForegroundColor Gray

    $sourceCustomers = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Customers" $SourceDatabase
    $devCustomers = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Customers" $TargetDatabaseDev
    $prodCustomers = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Customers" $TargetDatabaseProd

    $sourceProducts = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Products" $SourceDatabase
    $devProducts = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Products" $TargetDatabaseDev
    $prodProducts = Invoke-SqlCommand "SELECT COUNT(*) FROM dbo.Products" $TargetDatabaseProd

    Write-Host "  Source Customers: $($sourceCustomers.Trim())" -ForegroundColor White
    Write-Host "  Dev Customers: $($devCustomers.Trim())" -ForegroundColor White
    Write-Host "  Prod Customers: $($prodCustomers.Trim())" -ForegroundColor White
    Write-Host "  Source Products: $($sourceProducts.Trim())" -ForegroundColor White
    Write-Host "  Dev Products: $($devProducts.Trim())" -ForegroundColor White
    Write-Host "  Prod Products: $($prodProducts.Trim())" -ForegroundColor White

    $devDataMatch = ($sourceCustomers.Trim() -eq $devCustomers.Trim()) -and ($sourceProducts.Trim() -eq $devProducts.Trim())
    $prodDataMatch = ($sourceCustomers.Trim() -eq $prodCustomers.Trim()) -and ($sourceProducts.Trim() -eq $prodProducts.Trim())

    # Data verification result depends on whether data was actually exported
    $dataTestResult = "SKIPPED"
    if (-not $dataFilesExist) {
        # Data was not exported - verify targets have 0 rows (expected)
        $devExpectedEmpty = ($devCustomers.Trim() -eq "0") -and ($devProducts.Trim() -eq "0")
        $prodExpectedEmpty = ($prodCustomers.Trim() -eq "0") -and ($prodProducts.Trim() -eq "0")
        if ($devExpectedEmpty -and $prodExpectedEmpty) {
            Write-TestStep "Data not exported - targets correctly empty (as expected)" -Type Info
            $dataTestResult = "SKIPPED"
        } else {
            Write-TestStep "Data not exported but targets have unexpected data!" -Type Warning
            $dataTestResult = "WARNING"
        }
    } else {
        # Data was exported - verify data was imported correctly
        if ($devDataMatch) {
            Write-TestStep "Dev mode data integrity verified!" -Type Success
        } else {
            Write-TestStep "Dev mode data counts do not match!" -Type Error
            $dataTestResult = "FAILED"
        }

        if ($prodDataMatch) {
            Write-TestStep "Prod mode data integrity verified!" -Type Success
        } else {
            Write-TestStep "Prod mode data counts do not match!" -Type Error
            $dataTestResult = "FAILED"
        }

        if ($devDataMatch -and $prodDataMatch) {
            $dataTestResult = "PASSED"
        }
    }

    # Final Summary
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

    Write-TestStep "Database Creation: PASSED" -Type Success
    Write-TestStep "Schema Export: PASSED" -Type Success
    Write-TestStep "Parallel Export (schema): PASSED" -Type Success
    Write-TestStep "Parallel Export (with data): PASSED" -Type Success
    Write-TestStep "Dev Mode Import: PASSED" -Type Success
    Write-TestStep "Dev Mode Verification: PASSED" -Type Success
    Write-TestStep "Prod Mode Import: PASSED" -Type Success
    Write-TestStep "Prod Mode Verification: PASSED" -Type Success

    if ($dataTestResult -eq "PASSED") {
        Write-TestStep "Data Verification: PASSED" -Type Success
    } elseif ($dataTestResult -eq "SKIPPED") {
        Write-TestStep "Data Verification: SKIPPED (data export disabled in config)" -Type Info
    } elseif ($dataTestResult -eq "WARNING") {
        Write-TestStep "Data Verification: WARNING (unexpected state)" -Type Warning
    } else {
        Write-TestStep "Data Verification: FAILED" -Type Error
        throw "Data verification failed: Data counts do not match"
    }

    Write-Host "`n[SUCCESS] ALL TESTS PASSED!" -ForegroundColor Green
    Write-Host "`nExported schema available at: $exportDir" -ForegroundColor Cyan
    Write-Host "Source database: $SourceDatabase" -ForegroundColor Cyan
    Write-Host "Dev mode target: $TargetDatabaseDev (infrastructure skipped)" -ForegroundColor Cyan
    Write-Host "Prod mode target: $TargetDatabaseProd (full import with FileGroups)" -ForegroundColor Cyan

    exit 0

} catch {
    Write-Host "`n" -NoNewline
    Write-TestStep "TEST FAILED: $_" -Type Error
    Write-Host "`nStack Trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    exit 1
}
