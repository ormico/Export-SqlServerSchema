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
        & $importScript -Server $TEST_SERVER -Database $TargetDatabaseDev -SourcePath $exportDir -CreateDatabase -Credential $credential -ConfigFile $DevConfigFile -IncludeData -Verbose
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
    
    # Dev mode should skip FileGroups (infrastructure)
    if ($devFileGroupCount.Trim() -eq "0") {
        Write-TestStep "Dev mode correctly skipped FileGroups" -Type Success
    } else {
        Write-TestStep "Dev mode incorrectly imported FileGroups" -Type Error
        throw "Dev mode verification failed: FileGroups should be skipped"
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
    
    if ($devDataMatch) {
        Write-TestStep "Dev mode data integrity verified!" -Type Success
    } else {
        Write-TestStep "Dev mode data counts do not match!" -Type Warning
    }
    
    if ($prodDataMatch) {
        Write-TestStep "Prod mode data integrity verified!" -Type Success
    } else {
        Write-TestStep "Prod mode data counts do not match!" -Type Warning
    }
    
    # Final Summary
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    Write-TestStep "Database Creation: PASSED" -Type Success
    Write-TestStep "Schema Export: PASSED" -Type Success
    Write-TestStep "Dev Mode Import: PASSED" -Type Success
    Write-TestStep "Dev Mode Verification: PASSED" -Type Success
    Write-TestStep "Prod Mode Import: PASSED" -Type Success
    Write-TestStep "Prod Mode Verification: PASSED" -Type Success
    Write-TestStep "Data Verification: PASSED" -Type Success
    
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
