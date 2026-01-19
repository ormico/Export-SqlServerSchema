#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the excludeObjectTypes configuration feature
    
.DESCRIPTION
    This test validates that the excludeObjectTypes, excludeSchemas, and excludeObjects
    settings are respected across export logic by:
    1. Creating a test database with various object types
    2. Exporting with specific object types, schemas, and objects excluded
    3. Verifying that excluded objects were not exported
    4. Testing multiple exclusion patterns
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
} else {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

# Configuration
$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourceDatabase = $TEST_DATABASE
$ExportPath = Join-Path $PSScriptRoot "exports_exclude_test"
$ExcludeConfigFile = Join-Path $PSScriptRoot "test-exclude-config.yml"

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "EXCLUDE OBJECT TYPES FEATURE TEST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

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
    
    $lines = $result -split "`n" | Where-Object { $_.Trim() -ne "" }
    if ($lines.Count -gt 0) {
        $firstLine = $lines[0].Trim()
        if ($firstLine -match '^\d+$') {
            return $firstLine
        }
    }
    
    return $result
}

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
        Info = "[INFO]"
        Success = "[SUCCESS]"
        Error = "[ERROR]"
        Warning = "[WARNING]"
    }
    
    Write-Host "$($prefixes[$Type]) $Message" -ForegroundColor $colors[$Type]
}

try {
    # Step 1: Verify test database exists
    Write-TestStep "Step 1: Verifying test database exists..." -Type Info
    
    $dbExists = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.databases WHERE name = '$SourceDatabase'" "master"
    if ($dbExists.Trim() -eq "0") {
        Write-TestStep "Test database doesn't exist. Run run-integration-test.ps1 first." -Type Error
        exit 1
    }
    
    # Count objects in source database
    $sourceViews = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $SourceDatabase
    $sourceProcs = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $SourceDatabase
    $sourceFuncs = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.objects WHERE type IN ('FN', 'IF', 'TF') AND is_ms_shipped = 0" $SourceDatabase
    $sourceSynonyms = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.synonyms" $SourceDatabase
    $sourceSequences = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.sequences WHERE is_ms_shipped = 0" $SourceDatabase
    $sourceDbTriggers = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 0" $SourceDatabase
    $sourceTableTriggers = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.triggers WHERE parent_class = 1" $SourceDatabase
    $sourcePartitionFuncs = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.partition_functions" $SourceDatabase
    $sourcePartitionSchemes = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.partition_schemes" $SourceDatabase
    $sourceSecurityPolicies = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.security_policies" $SourceDatabase
    
    Write-Host "`nSource Database Object Counts:" -ForegroundColor White
    Write-Host "  Views: $($sourceViews.Trim())" -ForegroundColor Gray
    Write-Host "  Stored Procedures: $($sourceProcs.Trim())" -ForegroundColor Gray
    Write-Host "  Functions: $($sourceFuncs.Trim())" -ForegroundColor Gray
    Write-Host "  Synonyms: $($sourceSynonyms.Trim())" -ForegroundColor Gray
    Write-Host "  Sequences: $($sourceSequences.Trim())" -ForegroundColor Gray
    Write-Host "  Database Triggers: $($sourceDbTriggers.Trim())" -ForegroundColor Gray
    Write-Host "  Table Triggers: $($sourceTableTriggers.Trim())" -ForegroundColor Gray
    Write-Host "  Partition Functions: $($sourcePartitionFuncs.Trim())" -ForegroundColor Gray
    Write-Host "  Partition Schemes: $($sourcePartitionSchemes.Trim())" -ForegroundColor Gray
    Write-Host "  Security Policies: $($sourceSecurityPolicies.Trim())" -ForegroundColor Gray
    
    Write-TestStep "Source database verified" -Type Success
    
    # Step 2: Export with exclusions
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 2: Exporting schema with exclusions..." -Type Info
    
    # Clean export directory
    if (Test-Path $ExportPath) {
        Write-Host "  Cleaning previous exports..." -ForegroundColor Gray
        Remove-Item $ExportPath -Recurse -Force
    }
    
    $exportScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Export-SqlServerSchema.ps1"
    if (-not (Test-Path $exportScript)) {
        throw "Export script not found: $exportScript"
    }
    
    # Build credential object
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)
    
    Write-Host "  Running export with exclude config..." -ForegroundColor Gray
    Write-Host "  Config file: $ExcludeConfigFile" -ForegroundColor Gray
    
    try {
        & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $ExportPath -TargetSqlVersion 'Sql2022' -IncludeData -Credential $credential -ConfigFile $ExcludeConfigFile
        Write-TestStep "Schema exported with exclusions" -Type Success
    } catch {
        Write-TestStep "Export failed: $_" -Type Error
        throw $_
    }
    
    # Step 3: Verify exclusions
    Write-Host "`n" -NoNewline
    Write-TestStep "Step 3: Verifying excluded objects were not exported..." -Type Info
    
    $exportDirs = Get-ChildItem $ExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
    if ($exportDirs.Count -eq 0) {
        throw "No export directory created"
    }
    
    $exportDir = $exportDirs[0].FullName
    Write-Host "  Export location: $exportDir" -ForegroundColor Gray
    
    # Check for excluded object types
    $testResults = @{}
    
    # Test 1: Views should not be exported
    $viewsDir = Join-Path $exportDir "13_Programmability/05_Views"
    if (Test-Path $viewsDir) {
        $viewFiles = Get-ChildItem $viewsDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($viewFiles.Count -gt 0) {
            Write-TestStep "FAIL: Views were exported despite exclusion ($($viewFiles.Count) files found)" -Type Error
            $testResults['Views'] = $false
        } else {
            Write-TestStep "PASS: Views directory empty" -Type Success
            $testResults['Views'] = $true
        }
    } else {
        Write-TestStep "PASS: Views directory not created" -Type Success
        $testResults['Views'] = $true
    }
    
    # Test 2: Stored Procedures should not be exported
    $procsDir = Join-Path $exportDir "13_Programmability/03_StoredProcedures"
    if (Test-Path $procsDir) {
        $procFiles = Get-ChildItem $procsDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($procFiles.Count -gt 0) {
            Write-TestStep "FAIL: Stored Procedures were exported despite exclusion ($($procFiles.Count) files found)" -Type Error
            $testResults['StoredProcedures'] = $false
        } else {
            Write-TestStep "PASS: Stored Procedures directory empty" -Type Success
            $testResults['StoredProcedures'] = $true
        }
    } else {
        Write-TestStep "PASS: Stored Procedures directory not created" -Type Success
        $testResults['StoredProcedures'] = $true
    }
    
    # Test 3: Functions should not be exported
    $funcsDir = Join-Path $exportDir "13_Programmability/02_Functions"
    if (Test-Path $funcsDir) {
        $funcFiles = Get-ChildItem $funcsDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($funcFiles.Count -gt 0) {
            Write-TestStep "FAIL: Functions were exported despite exclusion ($($funcFiles.Count) files found)" -Type Error
            $testResults['Functions'] = $false
        } else {
            Write-TestStep "PASS: Functions directory empty" -Type Success
            $testResults['Functions'] = $true
        }
    } else {
        Write-TestStep "PASS: Functions directory not created" -Type Success
        $testResults['Functions'] = $true
    }
    
    # Test 4: Sequences should not be exported
    $seqDir = Join-Path $exportDir "03_Sequences"
    if (Test-Path $seqDir) {
        $seqFiles = Get-ChildItem $seqDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($seqFiles.Count -gt 0) {
            Write-TestStep "FAIL: Sequences were exported despite exclusion ($($seqFiles.Count) files found)" -Type Error
            $testResults['Sequences'] = $false
        } else {
            Write-TestStep "PASS: Sequences directory empty" -Type Success
            $testResults['Sequences'] = $true
        }
    } else {
        Write-TestStep "PASS: Sequences directory not created" -Type Success
        $testResults['Sequences'] = $true
    }
    
    # Test 5: Synonyms should not be exported
    $synDir = Join-Path $exportDir "14_Synonyms"
    if (Test-Path $synDir) {
        $synFiles = Get-ChildItem $synDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($synFiles.Count -gt 0) {
            Write-TestStep "FAIL: Synonyms were exported despite exclusion ($($synFiles.Count) files found)" -Type Error
            $testResults['Synonyms'] = $false
        } else {
            Write-TestStep "PASS: Synonyms directory empty" -Type Success
            $testResults['Synonyms'] = $true
        }
    } else {
        Write-TestStep "PASS: Synonyms directory not created" -Type Success
        $testResults['Synonyms'] = $true
    }
    
    # Test 6: Database Triggers should not be exported
    $triggerDir = Join-Path $exportDir "13_Programmability/04_Triggers"
    if (Test-Path $triggerDir) {
        $dbTriggerFiles = Get-ChildItem $triggerDir -Filter "Database.*.sql" -ErrorAction SilentlyContinue
        if ($dbTriggerFiles.Count -gt 0) {
            Write-TestStep "FAIL: Database Triggers were exported despite exclusion ($($dbTriggerFiles.Count) files found)" -Type Error
            $testResults['DatabaseTriggers'] = $false
        } else {
            Write-TestStep "PASS: Database Triggers not exported" -Type Success
            $testResults['DatabaseTriggers'] = $true
        }
    } else {
        Write-TestStep "PASS: Triggers directory not created" -Type Success
        $testResults['DatabaseTriggers'] = $true
    }
    
    # Test 7: Table Triggers should not be exported
    if (Test-Path $triggerDir) {
        $tableTriggerFiles = Get-ChildItem $triggerDir -Filter "*.sql" -ErrorAction SilentlyContinue | 
            Where-Object { $_.Name -notlike "Database.*" }
        if ($tableTriggerFiles.Count -gt 0) {
            Write-TestStep "FAIL: Table Triggers were exported despite exclusion ($($tableTriggerFiles.Count) files found)" -Type Error
            $testResults['TableTriggers'] = $false
        } else {
            Write-TestStep "PASS: Table Triggers not exported" -Type Success
            $testResults['TableTriggers'] = $true
        }
    } else {
        Write-TestStep "PASS: Table Triggers not exported (no trigger directory)" -Type Success
        $testResults['TableTriggers'] = $true
    }
    
    # Test 8: Partition Functions should not be exported
    $pfDir = Join-Path $exportDir "04_PartitionFunctions"
    if (Test-Path $pfDir) {
        $pfFiles = Get-ChildItem $pfDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($pfFiles.Count -gt 0) {
            Write-TestStep "FAIL: Partition Functions were exported despite exclusion ($($pfFiles.Count) files found)" -Type Error
            $testResults['PartitionFunctions'] = $false
        } else {
            Write-TestStep "PASS: Partition Functions directory empty" -Type Success
            $testResults['PartitionFunctions'] = $true
        }
    } else {
        Write-TestStep "PASS: Partition Functions directory not created" -Type Success
        $testResults['PartitionFunctions'] = $true
    }
    
    # Test 9: Partition Schemes should not be exported
    $psDir = Join-Path $exportDir "05_PartitionSchemes"
    if (Test-Path $psDir) {
        $psFiles = Get-ChildItem $psDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($psFiles.Count -gt 0) {
            Write-TestStep "FAIL: Partition Schemes were exported despite exclusion ($($psFiles.Count) files found)" -Type Error
            $testResults['PartitionSchemes'] = $false
        } else {
            Write-TestStep "PASS: Partition Schemes directory empty" -Type Success
            $testResults['PartitionSchemes'] = $true
        }
    } else {
        Write-TestStep "PASS: Partition Schemes directory not created" -Type Success
        $testResults['PartitionSchemes'] = $true
    }
    
    # Test 10: Security Policies should not be exported
    $spDir = Join-Path $exportDir "19_Security"
    if (Test-Path $spDir) {
        $spFiles = Get-ChildItem $spDir -Filter "*.securitypolicy.sql" -ErrorAction SilentlyContinue
        if ($spFiles.Count -gt 0) {
            Write-TestStep "FAIL: Security Policies were exported despite exclusion ($($spFiles.Count) files found)" -Type Error
            $testResults['SecurityPolicies'] = $false
        } else {
            Write-TestStep "PASS: Security Policies not exported" -Type Success
            $testResults['SecurityPolicies'] = $true
        }
    } else {
        Write-TestStep "PASS: Security directory not created or no security policies exported" -Type Success
        $testResults['SecurityPolicies'] = $true
    }
    
    # Test 11: Tables SHOULD be exported (not in exclusion list)
    $tablesDir = Join-Path $exportDir "08_Tables_PrimaryKey"
    if (Test-Path $tablesDir) {
        $tableFiles = Get-ChildItem $tablesDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($tableFiles.Count -gt 0) {
            Write-TestStep "PASS: Tables were exported as expected ($($tableFiles.Count) files found)" -Type Success
            $testResults['Tables_Included'] = $true
        } else {
            Write-TestStep "FAIL: Tables were not exported but should have been" -Type Error
            $testResults['Tables_Included'] = $false
        }
    } else {
        Write-TestStep "FAIL: Tables directory not created" -Type Error
        $testResults['Tables_Included'] = $false
    }
    
    # Test 12: Schemas SHOULD be exported (not in exclusion list)
    $schemasDir = Join-Path $exportDir "02_Schemas"
    if (Test-Path $schemasDir) {
        $schemaFiles = Get-ChildItem $schemasDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($schemaFiles.Count -gt 0) {
            Write-TestStep "PASS: Schemas were exported as expected ($($schemaFiles.Count) files found)" -Type Success
            $testResults['Schemas_Included'] = $true
        } else {
            Write-TestStep "FAIL: Schemas were not exported but should have been" -Type Error
            $testResults['Schemas_Included'] = $false
        }
    } else {
        Write-TestStep "FAIL: Schemas directory not created" -Type Error
        $testResults['Schemas_Included'] = $false
    }

    # Test 13: Excluded schema should not be exported
    $warehouseFiles = Get-ChildItem $exportDir -Recurse -Filter "Warehouse.*.sql" -ErrorAction SilentlyContinue
    if ($warehouseFiles.Count -gt 0) {
        Write-TestStep "FAIL: Warehouse schema objects were exported despite exclusion ($($warehouseFiles.Count) files found)" -Type Error
        $testResults['Schemas_Excluded_Warehouse'] = $false
    } else {
        Write-TestStep "PASS: Warehouse schema objects not exported" -Type Success
        $testResults['Schemas_Excluded_Warehouse'] = $true
    }

    # Test 14: Excluded specific object should not be exported
    $productsFiles = Get-ChildItem $exportDir -Recurse -Filter "dbo.Products*.sql" -ErrorAction SilentlyContinue
    if ($productsFiles.Count -gt 0) {
        Write-TestStep "FAIL: dbo.Products was exported despite exclusion ($($productsFiles.Count) files found)" -Type Error
        $testResults['Objects_Excluded_Products'] = $false
    } else {
        Write-TestStep "PASS: dbo.Products not exported" -Type Success
        $testResults['Objects_Excluded_Products'] = $true
    }

    # Test 15: Excluded wildcard object should not be exported
    $orderDetailsFiles = Get-ChildItem $exportDir -Recurse -Filter "*OrderDetails*.sql" -ErrorAction SilentlyContinue
    if ($orderDetailsFiles.Count -gt 0) {
        Write-TestStep "FAIL: OrderDetails objects were exported despite exclusion ($($orderDetailsFiles.Count) files found)" -Type Error
        $testResults['Objects_Excluded_OrderDetails'] = $false
    } else {
        Write-TestStep "PASS: OrderDetails objects not exported" -Type Success
        $testResults['Objects_Excluded_OrderDetails'] = $true
    }

    # Test 16: Non-excluded objects should still be exported
    $expectedTables = @(
        "dbo.Customers.sql",
        "Sales.Orders.sql"
    )
    $missingTables = @()
    foreach ($tableName in $expectedTables) {
        $tablePath = Join-Path $tablesDir $tableName
        if (-not (Test-Path $tablePath)) {
            $missingTables += $tableName
        }
    }
    if ($missingTables.Count -gt 0) {
        Write-TestStep "FAIL: Expected tables not exported: $($missingTables -join ', ')" -Type Error
        $testResults['Objects_Included_Expected'] = $false
    } else {
        Write-TestStep "PASS: Expected tables exported" -Type Success
        $testResults['Objects_Included_Expected'] = $true
    }
    
    # Step 4: Summary
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan
    
    $passCount = ($testResults.Values | Where-Object { $_ -eq $true }).Count
    $totalTests = $testResults.Count
    
    Write-Host "Tests Passed: $passCount / $totalTests" -ForegroundColor $(if ($passCount -eq $totalTests) { "Green" } else { "Yellow" })
    
    $failedTests = $testResults.GetEnumerator() | Where-Object { $_.Value -eq $false }
    if ($failedTests.Count -gt 0) {
        Write-Host "`nFailed Tests:" -ForegroundColor Red
        foreach ($test in $failedTests) {
            Write-Host "  - $($test.Key)" -ForegroundColor Red
        }
        
        Write-Host "`n[ERROR] TESTS FAILED!" -ForegroundColor Red
        exit 1
    } else {
        Write-Host "`n[SUCCESS] ALL EXCLUSION TESTS PASSED!" -ForegroundColor Green
        Write-Host "The exclusion features are working correctly across all tested settings." -ForegroundColor Cyan
        exit 0
    }
    
} catch {
    Write-Host "`n" -NoNewline
    Write-TestStep "TEST FAILED: $_" -Type Error
    Write-Host "`nStack Trace:" -ForegroundColor Red
    Write-Host $_.ScriptStackTrace -ForegroundColor Gray
    exit 1
}
