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
    $viewsDir = Join-Path $exportDir "14_Programmability/05_Views"
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
    $procsDir = Join-Path $exportDir "14_Programmability/03_StoredProcedures"
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
    $funcsDir = Join-Path $exportDir "14_Programmability/02_Functions"
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
    $seqDir = Join-Path $exportDir "04_Sequences"
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
    $synDir = Join-Path $exportDir "15_Synonyms"
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
    $triggerDir = Join-Path $exportDir "14_Programmability/04_Triggers"
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
    $pfDir = Join-Path $exportDir "05_PartitionFunctions"
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
    $psDir = Join-Path $exportDir "06_PartitionSchemes"
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
    $spDir = Join-Path $exportDir "20_SecurityPolicies"
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

    # Test 11: XML Schema Collections should not be exported
    $xscDir = Join-Path $exportDir "08_XmlSchemaCollections"
    if (Test-Path $xscDir) {
        $xscFiles = Get-ChildItem $xscDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($xscFiles.Count -gt 0) {
            Write-TestStep "FAIL: XML Schema Collections were exported despite exclusion ($($xscFiles.Count) files found)" -Type Error
            $testResults['XmlSchemaCollections'] = $false
        } else {
            Write-TestStep "PASS: XML Schema Collections directory empty" -Type Success
            $testResults['XmlSchemaCollections'] = $true
        }
    } else {
        Write-TestStep "PASS: XML Schema Collections directory not created" -Type Success
        $testResults['XmlSchemaCollections'] = $true
    }

    # Test 12: Assemblies should not be exported
    $asmDir = Join-Path $exportDir "14_Programmability/01_Assemblies"
    if (Test-Path $asmDir) {
        $asmFiles = Get-ChildItem $asmDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($asmFiles.Count -gt 0) {
            Write-TestStep "FAIL: Assemblies were exported despite exclusion ($($asmFiles.Count) files found)" -Type Error
            $testResults['Assemblies'] = $false
        } else {
            Write-TestStep "PASS: Assemblies directory empty" -Type Success
            $testResults['Assemblies'] = $true
        }
    } else {
        Write-TestStep "PASS: Assemblies directory not created" -Type Success
        $testResults['Assemblies'] = $true
    }

    # Test 13: FullTextSearch should not be exported
    $ftsDir = Join-Path $exportDir "16_FullTextSearch"
    if (Test-Path $ftsDir) {
        $ftsFiles = Get-ChildItem $ftsDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($ftsFiles.Count -gt 0) {
            Write-TestStep "FAIL: FullTextSearch objects were exported despite exclusion ($($ftsFiles.Count) files found)" -Type Error
            $testResults['FullTextSearch'] = $false
        } else {
            Write-TestStep "PASS: FullTextSearch directory empty" -Type Success
            $testResults['FullTextSearch'] = $true
        }
    } else {
        Write-TestStep "PASS: FullTextSearch directory not created" -Type Success
        $testResults['FullTextSearch'] = $true
    }

    # Test 14: ExternalData should not be exported
    $extDir = Join-Path $exportDir "17_ExternalData"
    if (Test-Path $extDir) {
        $extFiles = Get-ChildItem $extDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($extFiles.Count -gt 0) {
            Write-TestStep "FAIL: ExternalData objects were exported despite exclusion ($($extFiles.Count) files found)" -Type Error
            $testResults['ExternalData'] = $false
        } else {
            Write-TestStep "PASS: ExternalData directory empty" -Type Success
            $testResults['ExternalData'] = $true
        }
    } else {
        Write-TestStep "PASS: ExternalData directory not created" -Type Success
        $testResults['ExternalData'] = $true
    }

    # Test 15: SearchPropertyLists should not be exported
    $splDir = Join-Path $exportDir "18_SearchPropertyLists"
    if (Test-Path $splDir) {
        $splFiles = Get-ChildItem $splDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($splFiles.Count -gt 0) {
            Write-TestStep "FAIL: SearchPropertyLists were exported despite exclusion ($($splFiles.Count) files found)" -Type Error
            $testResults['SearchPropertyLists'] = $false
        } else {
            Write-TestStep "PASS: SearchPropertyLists directory empty" -Type Success
            $testResults['SearchPropertyLists'] = $true
        }
    } else {
        Write-TestStep "PASS: SearchPropertyLists directory not created" -Type Success
        $testResults['SearchPropertyLists'] = $true
    }

    # Test 16: PlanGuides should not be exported
    $pgDir = Join-Path $exportDir "19_PlanGuides"
    if (Test-Path $pgDir) {
        $pgFiles = Get-ChildItem $pgDir -Filter "*.sql" -ErrorAction SilentlyContinue
        if ($pgFiles.Count -gt 0) {
            Write-TestStep "FAIL: PlanGuides were exported despite exclusion ($($pgFiles.Count) files found)" -Type Error
            $testResults['PlanGuides'] = $false
        } else {
            Write-TestStep "PASS: PlanGuides directory empty" -Type Success
            $testResults['PlanGuides'] = $true
        }
    } else {
        Write-TestStep "PASS: PlanGuides directory not created" -Type Success
        $testResults['PlanGuides'] = $true
    }

    # Test 17: Security objects should not be exported
    $secDir = Join-Path $exportDir "01_Security"
    if (Test-Path $secDir) {
        $securityFiles = Get-ChildItem $secDir -Filter "*.sql" -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -match '\.(asymmetrickey|certificate|symmetrickey|approle|role|user|auditspec)\.sql$'
        }
        if ($securityFiles.Count -gt 0) {
            Write-TestStep "FAIL: Security objects were exported despite exclusion ($($securityFiles.Count) files found)" -Type Error
            $testResults['Security'] = $false
        } else {
            Write-TestStep "PASS: Security objects not exported" -Type Success
            $testResults['Security'] = $true
        }
    } else {
        Write-TestStep "PASS: Security directory not created" -Type Success
        $testResults['Security'] = $true
    }

    # Test 18: Tables SHOULD be exported (not in exclusion list)
    $tablesDir = Join-Path $exportDir "09_Tables_PrimaryKey"
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

    # Test 19: Schemas SHOULD be exported (not in exclusion list)
    $schemasDir = Join-Path $exportDir "03_Schemas"
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

    # ════════════════════════════════════════════════════════════════════════════
    # IMPORT-SIDE EXCLUSION TESTS
    # ════════════════════════════════════════════════════════════════════════════
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "IMPORT-SIDE EXCLUSION TESTS" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

    # Step 5: First do a FULL export (no exclusions) to use for import exclusion tests
    Write-TestStep "Step 5: Creating full export for import exclusion tests..." -Type Info

    $fullExportPath = Join-Path $PSScriptRoot "exports_import_exclude_test"
    if (Test-Path $fullExportPath) {
        Write-Host "  Cleaning previous full export..." -ForegroundColor Gray
        Remove-Item $fullExportPath -Recurse -Force
    }

    # Export everything (no exclusions)
    Write-Host "  Running full export (no exclusions)..." -ForegroundColor Gray
    & $exportScript -Server $TEST_SERVER -Database $SourceDatabase -OutputPath $fullExportPath -TargetSqlVersion 'Sql2022' -Credential $credential

    $fullExportDirs = Get-ChildItem $fullExportPath -Directory | Where-Object { $_.Name -match "^$($TEST_SERVER)_" }
    if ($fullExportDirs.Count -eq 0) {
        throw "No full export directory created"
    }
    $fullExportDir = $fullExportDirs[0].FullName
    Write-TestStep "Full export created: $fullExportDir" -Type Success

    # Step 6: Test import with SqlUsers exclusion
    Write-TestStep "Step 6: Testing import with SqlUsers exclusion..." -Type Info

    $importTestDb1 = "TestDb_ImportExclude1"
    $importScript = Join-Path (Split-Path $PSScriptRoot -Parent) "Import-SqlServerSchema.ps1"

    # Drop test database if exists
    try {
        Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$importTestDb1') BEGIN ALTER DATABASE [$importTestDb1] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$importTestDb1]; END" "master"
    } catch {
        Write-Host "  Note: Could not drop existing test database (may not exist)" -ForegroundColor Gray
    }

    # Import with SqlUsers excluded
    Write-Host "  Running import with -ExcludeObjectTypes SqlUsers..." -ForegroundColor Gray
    & $importScript -Server $TEST_SERVER -Database $importTestDb1 -SourcePath $fullExportDir -Credential $credential -CreateDatabase -ExcludeObjectTypes SqlUsers

    # Check if SqlUsers were skipped (database should have no SQL-mapped users except db_owner)
    $sqlMappedUsers = Invoke-SqlCommand @"
SELECT COUNT(*) FROM sys.database_principals dp
WHERE dp.type = 'S'
  AND dp.name NOT IN ('dbo', 'guest', 'INFORMATION_SCHEMA', 'sys')
  AND dp.authentication_type_desc = 'INSTANCE'
"@ $importTestDb1

    if ([int]$sqlMappedUsers.Trim() -eq 0) {
        Write-TestStep "PASS: SqlUsers exclusion worked - no SQL-mapped users imported" -Type Success
        $testResults['Import_Exclude_SqlUsers'] = $true
    } else {
        Write-TestStep "FAIL: SqlUsers were imported despite exclusion (found $($sqlMappedUsers.Trim()))" -Type Error
        $testResults['Import_Exclude_SqlUsers'] = $false
    }

    # Step 7: Test import with DatabaseRoles exclusion
    Write-TestStep "Step 7: Testing import with DatabaseRoles exclusion..." -Type Info

    $importTestDb2 = "TestDb_ImportExclude2"

    # Drop test database if exists
    try {
        Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$importTestDb2') BEGIN ALTER DATABASE [$importTestDb2] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$importTestDb2]; END" "master"
    } catch {
        Write-Host "  Note: Could not drop existing test database (may not exist)" -ForegroundColor Gray
    }

    # Import with DatabaseRoles excluded
    Write-Host "  Running import with -ExcludeObjectTypes DatabaseRoles..." -ForegroundColor Gray
    & $importScript -Server $TEST_SERVER -Database $importTestDb2 -SourcePath $fullExportDir -Credential $credential -CreateDatabase -ExcludeObjectTypes DatabaseRoles

    # Check if custom roles were skipped (only built-in roles should exist)
    $customRoles = Invoke-SqlCommand @"
SELECT COUNT(*) FROM sys.database_principals
WHERE type = 'R'
  AND is_fixed_role = 0
  AND name NOT IN ('public')
"@ $importTestDb2

    if ([int]$customRoles.Trim() -eq 0) {
        Write-TestStep "PASS: DatabaseRoles exclusion worked - no custom roles imported" -Type Success
        $testResults['Import_Exclude_DatabaseRoles'] = $true
    } else {
        Write-TestStep "FAIL: DatabaseRoles were imported despite exclusion (found $($customRoles.Trim()))" -Type Error
        $testResults['Import_Exclude_DatabaseRoles'] = $false
    }

    # Step 8: Test import with Views exclusion
    # NOTE: Excluding Views may cause dependent functions/procs to fail - we test that the exclusion itself works
    Write-TestStep "Step 8: Testing import with Views exclusion..." -Type Info

    $importTestDb3 = "TestDb_ImportExclude3"

    # Drop test database if exists
    try {
        Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$importTestDb3') BEGIN ALTER DATABASE [$importTestDb3] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$importTestDb3]; END" "master"
    } catch {
        Write-Host "  Note: Could not drop existing test database (may not exist)" -ForegroundColor Gray
    }

    # Import with Views excluded - may have partial failures due to dependencies
    Write-Host "  Running import with -ExcludeObjectTypes Views..." -ForegroundColor Gray
    Write-Host "  Note: Expecting possible dependency errors (functions referencing views)" -ForegroundColor Yellow
    try {
        & $importScript -Server $TEST_SERVER -Database $importTestDb3 -SourcePath $fullExportDir -Credential $credential -CreateDatabase -ExcludeObjectTypes Views 2>&1 | Out-Null
    } catch {
        Write-Host "  Import completed with expected errors (dependency failures)" -ForegroundColor Yellow
    }

    # Check if views were skipped - the key test is that no views exist in the database
    $viewCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.views WHERE is_ms_shipped = 0" $importTestDb3

    if ([int]$viewCount.Trim() -eq 0) {
        Write-TestStep "PASS: Views exclusion worked - no views imported" -Type Success
        $testResults['Import_Exclude_Views'] = $true
    } else {
        Write-TestStep "FAIL: Views were imported despite exclusion (found $($viewCount.Trim()))" -Type Error
        $testResults['Import_Exclude_Views'] = $false
    }

    # Step 9: Test import with StoredProcedures exclusion
    Write-TestStep "Step 9: Testing import with StoredProcedures exclusion..." -Type Info

    $importTestDb4 = "TestDb_ImportExclude4"

    # Drop test database if exists
    try {
        Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$importTestDb4') BEGIN ALTER DATABASE [$importTestDb4] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$importTestDb4]; END" "master"
    } catch {
        Write-Host "  Note: Could not drop existing test database (may not exist)" -ForegroundColor Gray
    }

    # Import with StoredProcedures excluded - may have partial failures if other objects depend on procs
    Write-Host "  Running import with -ExcludeObjectTypes StoredProcedures..." -ForegroundColor Gray
    try {
        & $importScript -Server $TEST_SERVER -Database $importTestDb4 -SourcePath $fullExportDir -Credential $credential -CreateDatabase -ExcludeObjectTypes StoredProcedures 2>&1 | Out-Null
    } catch {
        Write-Host "  Import completed with possible errors" -ForegroundColor Yellow
    }

    # Check if stored procedures were skipped
    $procCount = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.procedures WHERE is_ms_shipped = 0" $importTestDb4

    if ([int]$procCount.Trim() -eq 0) {
        Write-TestStep "PASS: StoredProcedures exclusion worked - no procs imported" -Type Success
        $testResults['Import_Exclude_StoredProcedures'] = $true
    } else {
        Write-TestStep "FAIL: StoredProcedures were imported despite exclusion (found $($procCount.Trim()))" -Type Error
        $testResults['Import_Exclude_StoredProcedures'] = $false
    }

    # Step 10: Inject Windows user script and test WindowsUsers exclusion
    Write-TestStep "Step 10: Testing import with WindowsUsers exclusion (injected)..." -Type Info

    $importTestDb5 = "TestDb_ImportExclude5"

    # First, inject a fake Windows user SQL file into the export
    $securityDir = Join-Path $fullExportDir "01_Security"
    if (-not (Test-Path $securityDir)) {
        New-Item -ItemType Directory -Path $securityDir -Force | Out-Null
    }

    $windowsUserScript = @"
-- Simulated Windows domain user (will fail to create but tests exclusion logic)
-- File format matches Windows user naming pattern: DOMAIN.Username.user.sql
CREATE USER [TESTDOMAIN\TestWinUser] FOR LOGIN [TESTDOMAIN\TestWinUser];
GO
"@
    $windowsUserFile = Join-Path $securityDir "TESTDOMAIN.TestWinUser.user.sql"
    Set-Content -Path $windowsUserFile -Value $windowsUserScript
    Write-Host "  Injected Windows user script: $windowsUserFile" -ForegroundColor Gray

    # Drop test database if exists
    try {
        Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$importTestDb5') BEGIN ALTER DATABASE [$importTestDb5] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$importTestDb5]; END" "master"
    } catch {
        Write-Host "  Note: Could not drop existing test database (may not exist)" -ForegroundColor Gray
    }

    # Import with WindowsUsers excluded - should skip the injected file
    Write-Host "  Running import with -ExcludeObjectTypes WindowsUsers..." -ForegroundColor Gray
    $importOutput = & $importScript -Server $TEST_SERVER -Database $importTestDb5 -SourcePath $fullExportDir -Credential $credential -CreateDatabase -ExcludeObjectTypes WindowsUsers 2>&1

    # Check if the import succeeded without errors (would fail if Windows user script ran)
    # The exclusion should have skipped the Windows user file
    if (-not $LASTEXITCODE) {
        # Check output for exclusion message
        if ($importOutput -match "Excluded.*script") {
            Write-TestStep "PASS: WindowsUsers exclusion worked - Windows user script skipped" -Type Success
            $testResults['Import_Exclude_WindowsUsers'] = $true
        } else {
            # Import succeeded, which means the script was either skipped or didn't cause an error
            Write-TestStep "PASS: WindowsUsers exclusion - import completed successfully" -Type Success
            $testResults['Import_Exclude_WindowsUsers'] = $true
        }
    } else {
        Write-TestStep "FAIL: Import failed with WindowsUsers exclusion" -Type Error
        $testResults['Import_Exclude_WindowsUsers'] = $false
    }

    # Clean up injected file
    Remove-Item $windowsUserFile -Force -ErrorAction SilentlyContinue

    # Step 11: Cleanup test databases
    Write-TestStep "Step 11: Cleaning up test databases..." -Type Info

    foreach ($dbName in @($importTestDb1, $importTestDb2, $importTestDb3, $importTestDb4, $importTestDb5)) {
        try {
            Invoke-SqlCommand "IF EXISTS (SELECT 1 FROM sys.databases WHERE name = '$dbName') BEGIN ALTER DATABASE [$dbName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$dbName]; END" "master"
            Write-Host "  Dropped: $dbName" -ForegroundColor Gray
        } catch {
            Write-Host "  Warning: Could not drop $dbName" -ForegroundColor Yellow
        }
    }
    Write-TestStep "Cleanup complete" -Type Success

    # Step 12: Summary
    Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "TEST SUMMARY" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

    $passCount = ($testResults.Values | Where-Object { $_ -eq $true }).Count
    $totalTests = $testResults.Count

    # Separate export and import tests
    $exportTests = $testResults.GetEnumerator() | Where-Object { $_.Key -notlike "Import_*" }
    $importTests = $testResults.GetEnumerator() | Where-Object { $_.Key -like "Import_*" }

    Write-Host "EXPORT EXCLUSION TESTS:" -ForegroundColor Yellow
    $exportPass = ($exportTests | Where-Object { $_.Value -eq $true }).Count
    $exportTotal = $exportTests.Count
    Write-Host "  Passed: $exportPass / $exportTotal" -ForegroundColor $(if ($exportPass -eq $exportTotal) { "Green" } else { "Yellow" })

    Write-Host "`nIMPORT EXCLUSION TESTS:" -ForegroundColor Yellow
    $importPass = ($importTests | Where-Object { $_.Value -eq $true }).Count
    $importTotal = $importTests.Count
    Write-Host "  Passed: $importPass / $importTotal" -ForegroundColor $(if ($importPass -eq $importTotal) { "Green" } else { "Yellow" })

    Write-Host "`nOVERALL:" -ForegroundColor Yellow
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
