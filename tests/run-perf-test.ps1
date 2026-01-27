#Requires -Version 7.0

<#
.SYNOPSIS
    Performance test runner for Export-SqlServerSchema and Import-SqlServerSchema

.DESCRIPTION
    This script:
    1. Creates the performance test database from create-perf-test-db-simplified.sql
    2. Exports it using Export-SqlServerSchema.ps1 with timing metrics
    3. Imports to a new database using Import-SqlServerSchema.ps1 with timing metrics
    4. Verifies object counts match between source and target
    5. Reports detailed performance metrics

.PARAMETER ConfigFile
    Path to .env configuration file (default: .env in script directory)

.PARAMETER ExportConfigYaml
    Path to YAML config file for export (for testing different groupBy modes)

.PARAMETER SkipDatabaseSetup
    Skip database creation/population if PerfTestDb already exists with data

.PARAMETER CleanupOnly
    Only clean up test databases without running tests

.PARAMETER NoData
    Run schema-only exports (no -IncludeData). Useful for comparing with older version baselines.

.EXAMPLE
    ./run-perf-test.ps1

.EXAMPLE
    # Run with specific groupBy config
    ./run-perf-test.ps1 -ExportConfigYaml ./test-groupby-all.yml

.EXAMPLE
    # Reuse existing test database
    ./run-perf-test.ps1 -SkipDatabaseSetup -ExportConfigYaml ./test-groupby-schema.yml

.EXAMPLE
    # Run schema-only export (no data) for baseline comparison
    ./run-perf-test.ps1 -NoData

.NOTES
    Prerequisites:
    - SQL Server running on localhost:1433
    - SA credentials: sa / Test@1234 (from .env)
    - Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1 in parent directory
#>

param(
    [string]$ConfigFile,
    [string]$ExportConfigYaml,
    [switch]$SkipDatabaseSetup,
    [switch]$CleanupOnly,
    [switch]$NoData
)

# Determine the config file location
if ([string]::IsNullOrEmpty($ConfigFile)) {
    # If not specified, look for .env in the script's directory
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $ConfigFile = Join-Path $scriptDir ".env"
}

$ErrorActionPreference = "Stop"
$VerbosePreference = "Continue"

# Load configuration from .env file
if (Test-Path $ConfigFile) {
    Write-Host "Loading configuration from $ConfigFile..." -ForegroundColor Cyan
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.+?)\s*$') {
            $name = $matches[1]
            $value = $matches[2]
            Set-Variable -Name $name -Value $value -Scope Script
            if ($_ -match 'PASSWORD|SECRET|KEY') {
                Write-Host "  $name = ********" -ForegroundColor Gray
            } else {
                Write-Host "  $name = $value" -ForegroundColor Gray
            }
        }
    }
} else {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourceDatabase = "PerfTestDb"
$TargetDatabase = "PerfTestDb_Restored"
$ExportPath = Join-Path $PSScriptRoot "exports_perf"
$PerftestScript = Join-Path $PSScriptRoot "create-perf-test-db-simplified.sql"
$ExportScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Export-SqlServerSchema.ps1"
$ImportScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Import-SqlServerSchema.ps1"

Write-Host "`n" -NoNewline
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "PERFORMANCE TEST: Export/Import Suite" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

# Helper function to execute SQL
function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )

    try {
        $result = Invoke-Sqlcmd -ServerInstance $Server -Username $Username -Password $Password `
            -Query $Query -Database $Database -Encrypt Optional -TrustServerCertificate -ErrorAction Stop 2>&1
        return $result
    } catch {
        throw "SQL Error: $_"
    }
}

# Helper function for formatted output
function Write-TestStep {
    param(
        [string]$Message,
        [ValidateSet("Info", "Success", "Error", "Warning")]
        [string]$Type = "Info",
        [TimeSpan]$Duration
    )

    $colors = @{
        Info = "Cyan"
        Success = "Green"
        Error = "Red"
        Warning = "Yellow"
    }

    $prefixes = @{
        Info = "[INFO]"
        Success = "[SUCCESS]"
        Error = "[ERROR]"
        Warning = "[WARNING]"
    }

    if ($Duration) {
        Write-Host "$($prefixes[$Type]) $Message ($($Duration.TotalSeconds)s)" -ForegroundColor $colors[$Type]
    } else {
        Write-Host "$($prefixes[$Type]) $Message" -ForegroundColor $colors[$Type]
    }
}

# Helper function to count database objects
function Get-DatabaseStats {
    param([string]$Database)

    $stats = @{}

    try {
        $tables = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE is_ms_shipped = 0" $Database).Column1
        $stats.Tables = $tables

        $views = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $Database).Column1
        $stats.Views = $views

        $procedures = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $Database).Column1
        $stats.Procedures = $procedures

        $functions = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0" $Database).Column1
        $stats.Functions = $functions

        $triggers = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.triggers WHERE parent_id IN (SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0)" $Database).Column1
        $stats.Triggers = $triggers

        $indexes = (Invoke-SqlCommand "SELECT COUNT(*) FROM sys.indexes WHERE object_id IN (SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0) AND type > 0" $Database).Column1
        $stats.Indexes = $indexes

        $rows = (Invoke-SqlCommand "SELECT SUM(p.rows) FROM sys.partitions p WHERE p.object_id IN (SELECT object_id FROM sys.tables WHERE is_ms_shipped = 0) AND p.index_id < 2" $Database).Column1
        $stats.Rows = [Int64]$rows

        return $stats
    } catch {
        Write-TestStep "Failed to get database stats for $Database : $_" -Type Error
        return $null
    }
}

# Helper function to check if database exists and has data
function Test-DatabaseExists {
    param([string]$Database)

    try {
        $result = Invoke-SqlCommand "SELECT DB_ID('$Database') AS DbId" "master"
        return ($null -ne $result.DbId)
    } catch {
        return $false
    }
}

# Helper function to force close connections and drop database
function Remove-TestDatabase {
    param([string]$Database)

    try {
        # Set to single user to kill all connections, then drop
        $sql = @"
IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$Database')
BEGIN
    ALTER DATABASE [$Database] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
    DROP DATABASE [$Database];
END
"@
        $null = Invoke-SqlCommand $sql "master"
        return $true
    } catch {
        # Try simple drop if alter fails
        try {
            $null = Invoke-SqlCommand "DROP DATABASE IF EXISTS [$Database]" "master"
            return $true
        } catch {
            return $false
        }
    }
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
            Write-TestStep "SQL Server is ready" -Type Success
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

    # Step 2: Auto-cleanup - Check and drop existing databases
    Write-TestStep "Step 2: Auto-cleanup - checking for existing test databases..." -Type Info

    $sourceExists = Test-DatabaseExists $SourceDatabase
    $targetExists = Test-DatabaseExists $TargetDatabase

    if ($sourceExists) {
        Write-Host "  Found existing $SourceDatabase - dropping..." -ForegroundColor Yellow
        if (Remove-TestDatabase $SourceDatabase) {
            Write-Host "  Dropped $SourceDatabase" -ForegroundColor Gray
        } else {
            throw "Failed to drop existing $SourceDatabase"
        }
    } else {
        Write-Host "  $SourceDatabase does not exist" -ForegroundColor Gray
    }

    if ($targetExists) {
        Write-Host "  Found existing $TargetDatabase - dropping..." -ForegroundColor Yellow
        if (Remove-TestDatabase $TargetDatabase) {
            Write-Host "  Dropped $TargetDatabase" -ForegroundColor Gray
        } else {
            throw "Failed to drop existing $TargetDatabase"
        }
    } else {
        Write-Host "  $TargetDatabase does not exist" -ForegroundColor Gray
    }

    # Handle CleanupOnly mode
    if ($CleanupOnly) {
        Write-TestStep "Cleanup completed. Exiting (CleanupOnly mode)." -Type Success
        exit 0
    }

    Start-Sleep -Seconds 2

    # Step 3: Create source database (skip if SkipDatabaseSetup and it exists with data)
    $skipSetup = $false
    if ($SkipDatabaseSetup) {
        # Re-check after cleanup - database was dropped, so we can't skip
        Write-TestStep "Note: -SkipDatabaseSetup specified but database was cleaned up. Creating fresh database." -Type Warning
    }

    Write-TestStep "Step 3: Creating source performance test database..." -Type Info
    $null = Invoke-SqlCommand "CREATE DATABASE $SourceDatabase" "master"
    Write-Host "  Database created" -ForegroundColor Gray
    Start-Sleep -Seconds 2

    # Step 4: Populate database
    Write-TestStep "Step 4: Populating database with test objects and data..." -Type Info
    Write-Host "  This will typically take 1-3 minutes for the simplified test database..." -ForegroundColor Yellow

    $scriptStart = Get-Date
    $scriptPath = $PerftestScript

    try {
        # Execute the script using sqlcmd which handles GO statements properly
        Write-Host "  Starting database population via sqlcmd..." -ForegroundColor Gray

        # Note: sqlcmd handles the database context switch via "USE PerfTestDb" in the script
        $cmdArgs = @(
            "-S", $Server,
            "-U", $Username,
            "-P", $Password,
            "-i", $scriptPath,
            "-b"  # Batch abort on error
        )

        # Run sqlcmd and capture output
        $output = @()
        & sqlcmd @cmdArgs 2>&1 | ForEach-Object {
            $output += $_
            # Show progress messages
            if ($_ -match 'Created|Populated|Granted|objects created') {
                Write-Host "  $_" -ForegroundColor Gray
            }
        }

        # Check for errors
        if ($LASTEXITCODE -ne 0) {
            $errorLines = $output | Where-Object { $_ -match 'Msg \d+|Error' }
            if ($errorLines) {
                throw "sqlcmd failed: $($errorLines | Select-Object -First 3 | Out-String)"
            }
        }

        Write-Host "  Database population completed" -ForegroundColor Gray
    } catch {
        Write-TestStep "Error during database population: $_" -Type Error
        throw $_
    }

    $scriptDuration = (Get-Date) - $scriptStart
    Write-Host "  [SUCCESS] Database population completed ($('{0:N2}' -f $scriptDuration.TotalSeconds)s)" -ForegroundColor Green

    # Step 5: Get source database statistics
    Write-TestStep "Step 5: Getting source database statistics..." -Type Info
    $sourceStats = Get-DatabaseStats $SourceDatabase

    if ($sourceStats) {
        Write-Host "  Tables: $($sourceStats.Tables)" -ForegroundColor White
        Write-Host "  Views: $($sourceStats.Views)" -ForegroundColor White
        Write-Host "  Procedures: $($sourceStats.Procedures)" -ForegroundColor White
        Write-Host "  Functions: $($sourceStats.Functions)" -ForegroundColor White
        Write-Host "  Triggers: $($sourceStats.Triggers)" -ForegroundColor White
        Write-Host "  Indexes: $($sourceStats.Indexes)" -ForegroundColor White
        Write-Host "  Total Rows: $($sourceStats.Rows)" -ForegroundColor White
        Write-TestStep "Database statistics retrieved" -Type Success
    }

    # Step 6: Export database
    Write-TestStep "Step 6: Exporting database with Export-SqlServerSchema.ps1..." -Type Info

    if (-not (Test-Path $ExportScript)) {
        throw "Export script not found: $ExportScript"
    }

    # Clean export directory
    if (Test-Path $ExportPath) {
        Write-Host "  Cleaning previous exports..." -ForegroundColor Gray
        Remove-Item $ExportPath -Recurse -Force
    }

    Write-Host "  Starting export..." -ForegroundColor Gray
    $exportStart = Get-Date

    # Build credential object
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    # Determine if data should be included
    $includeData = -not $NoData
    $dataMode = if ($includeData) { "with data" } else { "schema only (no data)" }
    Write-Host "  Export mode: $dataMode" -ForegroundColor Cyan

    # Run export with metrics collection
    $exportArgs = @{
        Server = $TEST_SERVER
        Database = $SourceDatabase
        OutputPath = $ExportPath
        IncludeData = $includeData
        Credential = $credential
        CollectMetrics = $true
    }

    # Add config file if specified (for groupBy testing)
    if ($ExportConfigYaml) {
        $exportArgs.ConfigFile = $ExportConfigYaml
        Write-Host "  Using config: $ExportConfigYaml" -ForegroundColor Cyan
    }

    & $ExportScript @exportArgs

    $exportDuration = (Get-Date) - $exportStart

    # Count exported files
    $exportedFiles = (Get-ChildItem $ExportPath -Recurse -File | Measure-Object).Count
    Write-Host "  Exported $exportedFiles files" -ForegroundColor Gray

    Write-Host "  [SUCCESS] Sequential export completed ($('{0:N2}' -f $exportDuration.TotalSeconds)s)" -ForegroundColor Green

    # Step 6b: Parallel Export (comparison)
    Write-TestStep "Step 6b: Running parallel export for performance comparison..." -Type Info

    $parallelExportPath = Join-Path $PSScriptRoot "exports_perf_parallel"

    # Clean parallel export directory
    if (Test-Path $parallelExportPath) {
        Write-Host "  Cleaning previous parallel exports..." -ForegroundColor Gray
        Remove-Item $parallelExportPath -Recurse -Force
    }

    Write-Host "  Starting parallel export (default workers)..." -ForegroundColor Gray
    $parallelExportStart = Get-Date

    # Build parallel export args - use the parallel config file
    $parallelConfigFile = Join-Path $PSScriptRoot "test-parallel-config.yml"
    $parallelExportArgs = @{
        Server = $TEST_SERVER
        Database = $SourceDatabase
        OutputPath = $parallelExportPath
        IncludeData = $includeData
        Credential = $credential
        CollectMetrics = $true
        ConfigFile = $parallelConfigFile
    }

    & $ExportScript @parallelExportArgs

    $parallelExportDuration = (Get-Date) - $parallelExportStart

    # Count parallel exported files
    $parallelExportedFiles = (Get-ChildItem $parallelExportPath -Recurse -File | Measure-Object).Count
    Write-Host "  Exported $parallelExportedFiles files" -ForegroundColor Gray

    Write-Host "  [SUCCESS] Parallel export completed ($('{0:N2}' -f $parallelExportDuration.TotalSeconds)s)" -ForegroundColor Green

    # Calculate speedup
    $speedup = $exportDuration.TotalSeconds / $parallelExportDuration.TotalSeconds
    if ($speedup -gt 1) {
        Write-Host "  [INFO] Parallel speedup: $([math]::Round($speedup, 2))x faster" -ForegroundColor Cyan
    } else {
        Write-Host "  [INFO] Parallel speedup: $([math]::Round($speedup, 2))x (no improvement)" -ForegroundColor Yellow
    }

    # Verify parallel export produces same number of files
    if ($exportedFiles -eq $parallelExportedFiles) {
        Write-Host "  [SUCCESS] File counts match: $exportedFiles files" -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] File count mismatch: Sequential=$exportedFiles Parallel=$parallelExportedFiles" -ForegroundColor Yellow
    }

    # Step 7: Import database
    Write-TestStep "Step 7: Importing database with Import-SqlServerSchema.ps1..." -Type Info

    if (-not (Test-Path $ImportScript)) {
        throw "Import script not found: $ImportScript"
    }

    Write-Host "  Starting import..." -ForegroundColor Gray
    $importStart = Get-Date

    # Find the export directory
    $exportDir = Get-ChildItem $ExportPath -Directory | Select-Object -First 1
    if (-not $exportDir) {
        throw "No export directories found in $ExportPath"
    }

    # Run import
    $importArgs = @{
        Server = $TEST_SERVER
        Database = $TargetDatabase
        SourcePath = $exportDir.FullName
        IncludeData = $includeData
        CreateDatabase = $true
        Credential = $credential
        CollectMetrics = $true
    }
    & $ImportScript @importArgs

    $importDuration = (Get-Date) - $importStart
    Write-Host "  [SUCCESS] Database import completed ($('{0:N2}' -f $importDuration.TotalSeconds)s)" -ForegroundColor Green

    # Step 8: Verify target database
    Write-TestStep "Step 8: Verifying target database integrity..." -Type Info
    $targetStats = Get-DatabaseStats $TargetDatabase

    if ($targetStats) {
        Write-Host "  Tables: $($targetStats.Tables)" -ForegroundColor White
        Write-Host "  Views: $($targetStats.Views)" -ForegroundColor White
        Write-Host "  Procedures: $($targetStats.Procedures)" -ForegroundColor White
        Write-Host "  Functions: $($targetStats.Functions)" -ForegroundColor White
        Write-Host "  Triggers: $($targetStats.Triggers)" -ForegroundColor White
        Write-Host "  Indexes: $($targetStats.Indexes)" -ForegroundColor White
        Write-Host "  Total Rows: $($targetStats.Rows)" -ForegroundColor White
        Write-TestStep "Database statistics retrieved" -Type Success
    }

    # Step 9: Compare statistics
    Write-TestStep "Step 9: Comparing source and target databases..." -Type Info

    $allMatch = $true
    $compareResults = @()

    foreach ($key in $sourceStats.Keys) {
        $match = $sourceStats[$key] -eq $targetStats[$key]
        $status = if ($match) { "OK" } else { "MISMATCH" }
        $compareResults += @{
            Object = $key
            Source = $sourceStats[$key]
            Target = $targetStats[$key]
            Match = $match
            Status = $status
        }

        if (-not $match) {
            $allMatch = $false
            Write-Host "  [$status] $key : Source=$($sourceStats[$key]) Target=$($targetStats[$key])" -ForegroundColor Yellow
        } else {
            Write-Host "  [OK] $key : $($sourceStats[$key])" -ForegroundColor Gray
        }
    }

    if ($allMatch) {
        Write-TestStep "All objects match between source and target" -Type Success
    } else {
        Write-TestStep "Some objects do not match between source and target" -Type Warning
    }

    # Final Summary
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "PERFORMANCE METRICS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan

    Write-Host ""
    if ($ExportConfigYaml) {
        $configName = Split-Path $ExportConfigYaml -Leaf
        Write-Host "Test Configuration: $configName" -ForegroundColor Magenta
    }
    Write-Host "Data Mode: $dataMode" -ForegroundColor Magenta
    Write-Host ""

    Write-Host "Database Setup:" -ForegroundColor Yellow
    Write-Host "  Population Time: $([math]::Round($scriptDuration.TotalSeconds, 2))s" -ForegroundColor White

    Write-Host ""
    Write-Host "Export Performance:" -ForegroundColor Yellow
    Write-Host "  Sequential:" -ForegroundColor White
    Write-Host "    Duration: $([math]::Round($exportDuration.TotalSeconds, 2))s" -ForegroundColor White
    Write-Host "    Files Generated: $exportedFiles" -ForegroundColor White
    Write-Host "    Export Speed: $([math]::Round($sourceStats.Rows / $exportDuration.TotalSeconds, 0)) rows/sec" -ForegroundColor White
    Write-Host "  Parallel:" -ForegroundColor White
    Write-Host "    Duration: $([math]::Round($parallelExportDuration.TotalSeconds, 2))s" -ForegroundColor White
    Write-Host "    Files Generated: $parallelExportedFiles" -ForegroundColor White
    Write-Host "    Export Speed: $([math]::Round($sourceStats.Rows / $parallelExportDuration.TotalSeconds, 0)) rows/sec" -ForegroundColor White
    Write-Host "  Speedup: $([math]::Round($speedup, 2))x" -ForegroundColor $(if ($speedup -gt 1) { 'Green' } else { 'Yellow' })

    Write-Host ""
    Write-Host "Import Performance:" -ForegroundColor Yellow
    Write-Host "  Duration: $([math]::Round($importDuration.TotalSeconds, 2))s" -ForegroundColor White
    Write-Host "  Import Speed: $([math]::Round($targetStats.Rows / $importDuration.TotalSeconds, 0)) rows/sec" -ForegroundColor White

    Write-Host ""
    Write-Host "Total Round-Trip Time:" -ForegroundColor Yellow
    $totalDuration = $exportDuration + $importDuration
    Write-Host "  Export + Import: $([math]::Round($totalDuration.TotalSeconds, 2))s" -ForegroundColor White

    # Save metrics to JSON for comparison
    $metricsResult = @{
        Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        ConfigFile = if ($ExportConfigYaml) { Split-Path $ExportConfigYaml -Leaf } else { "default (single)" }
        IncludeData = $includeData
        DatabasePopulationSeconds = [math]::Round($scriptDuration.TotalSeconds, 2)
        SequentialExport = @{
            DurationSeconds = [math]::Round($exportDuration.TotalSeconds, 2)
            FilesGenerated = $exportedFiles
            RowsPerSecond = [math]::Round($sourceStats.Rows / $exportDuration.TotalSeconds, 0)
        }
        ParallelExport = @{
            DurationSeconds = [math]::Round($parallelExportDuration.TotalSeconds, 2)
            FilesGenerated = $parallelExportedFiles
            RowsPerSecond = [math]::Round($sourceStats.Rows / $parallelExportDuration.TotalSeconds, 0)
        }
        ParallelSpeedup = [math]::Round($speedup, 2)
        ImportDurationSeconds = [math]::Round($importDuration.TotalSeconds, 2)
        ImportRowsPerSecond = [math]::Round($targetStats.Rows / $importDuration.TotalSeconds, 0)
        TotalRoundTripSeconds = [math]::Round($totalDuration.TotalSeconds, 2)
        SourceStats = $sourceStats
        TargetStats = $targetStats
        AllObjectsMatch = $allMatch
    }

    $metricsFileName = "perf-metrics-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
    $metricsFilePath = Join-Path $PSScriptRoot $metricsFileName
    $metricsResult | ConvertTo-Json -Depth 3 | Set-Content $metricsFilePath
    Write-Host ""
    Write-Host "Metrics saved to: $metricsFileName" -ForegroundColor Gray

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "TEST COMPLETED SUCCESSFULLY" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""

} catch {
    Write-Host ""
    Write-TestStep "TEST FAILED: $_" -Type Error
    Write-Host ""
    exit 1
}
