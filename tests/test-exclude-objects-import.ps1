#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the -ExcludeObjects parameter for Import-SqlServerSchema.ps1

.DESCRIPTION
    This test validates that the -ExcludeObjects parameter correctly filters out
    scripts by schema.objectName pattern during import. It tests:
    1. Test-ObjectExcluded function directly (exact match, wildcards, non-schema-bound)
    2. Get-ScriptFiles filtering with mock SQL files
    3. CLI parameter and type validation
    4. JSON schema and config key validation
    5. Config merge precedence (CLI overrides config, config fallback)
#>

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

# Test counters
$script:TestsPassed = 0
$script:TestsFailed = 0
$script:TestsRun = 0

function Write-TestResult {
  param([string]$Name, [bool]$Passed, [string]$Details = '')
  $script:TestsRun++
  if ($Passed) {
    $script:TestsPassed++
    Write-Host "  [PASS] $Name" -ForegroundColor Green
  } else {
    $script:TestsFailed++
    Write-Host "  [FAIL] $Name" -ForegroundColor Red
    if ($Details) { Write-Host "         $Details" -ForegroundColor Yellow }
  }
}

Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "ExcludeObjects Import Test" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load the import script to get access to Test-ObjectExcluded ──
# Extract the function definition and define it in test scope via ScriptBlock.

$importScript = Join-Path $PSScriptRoot '..' 'Import-SqlServerSchema.ps1'
if (-not (Test-Path $importScript)) {
  Write-Host "[ERROR] Import-SqlServerSchema.ps1 not found at $importScript" -ForegroundColor Red
  exit 1
}

$scriptContent = Get-Content $importScript -Raw

# Extract function and dot-source via temp file to define in caller scope
if ($scriptContent -match '(?ms)(function Test-ObjectExcluded \{.+?\n\})') {
  $tempFunc = Join-Path ([System.IO.Path]::GetTempPath()) "Test-ObjectExcluded_$(Get-Random).ps1"
  $matches[1] | Out-File -FilePath $tempFunc -Encoding utf8
  . $tempFunc
  Remove-Item $tempFunc -Force
} else {
  Write-Host "[ERROR] Could not extract Test-ObjectExcluded function from Import-SqlServerSchema.ps1" -ForegroundColor Red
  exit 1
}

# ═══════════════════════════════════════════════════════════════
# PHASE 1: Test Test-ObjectExcluded directly
# ═══════════════════════════════════════════════════════════════
Write-Host "[PHASE 1] Test-ObjectExcluded function" -ForegroundColor Yellow

# Create temp directory structure mimicking export layout
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "ExcludeObjectsTest_$(Get-Random)"
$tablesDir = Join-Path $tempRoot 'Tables'
$viewsDir = Join-Path $tempRoot 'Views'
$funcsDir = Join-Path $tempRoot 'Functions'
$procsDir = Join-Path $tempRoot 'StoredProcedures'
$schemasDir = Join-Path $tempRoot 'Schemas'

New-Item -ItemType Directory -Path $tablesDir -Force | Out-Null
New-Item -ItemType Directory -Path $viewsDir -Force | Out-Null
New-Item -ItemType Directory -Path $funcsDir -Force | Out-Null
New-Item -ItemType Directory -Path $procsDir -Force | Out-Null
New-Item -ItemType Directory -Path $schemasDir -Force | Out-Null

# Create mock SQL files
$mockFiles = @(
  (Join-Path $tablesDir 'dbo.Users.sql'),
  (Join-Path $tablesDir 'dbo.Orders.sql'),
  (Join-Path $tablesDir 'staging.ImportData.sql'),
  (Join-Path $tablesDir 'app.Config.sql'),
  (Join-Path $viewsDir 'dbo.vw_ActiveUsers.sql'),
  (Join-Path $viewsDir 'staging.vw_RawData.sql'),
  (Join-Path $funcsDir 'dbo.fn_GetCount.function.sql'),
  (Join-Path $funcsDir '001_dbo.fn_Grouped.function.sql'),
  (Join-Path $procsDir 'dbo.usp_LegacyProc.sql'),
  (Join-Path $procsDir 'app.sp_ProcessUser.sql'),
  (Join-Path $schemasDir 'staging.sql')
)

foreach ($f in $mockFiles) {
  'SELECT 1;' | Out-File -FilePath $f -Encoding utf8
}

try {
  # Test 1: Exact match
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $procsDir 'dbo.usp_LegacyProc.sql') -ExcludeObjects @('dbo.usp_LegacyProc')
  Write-TestResult -Name "Exact match: dbo.usp_LegacyProc excluded" -Passed ($result -eq $true)

  # Test 2: No match
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'dbo.Users.sql') -ExcludeObjects @('dbo.usp_LegacyProc')
  Write-TestResult -Name "No match: dbo.Users not excluded by dbo.usp_LegacyProc" -Passed ($result -eq $false)

  # Test 3: Wildcard schema.* excludes all objects in schema
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'staging.ImportData.sql') -ExcludeObjects @('staging.*')
  Write-TestResult -Name "Wildcard: staging.* excludes staging.ImportData" -Passed ($result -eq $true)

  # Test 4: Wildcard *.objectName excludes across schemas
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $viewsDir 'dbo.vw_ActiveUsers.sql') -ExcludeObjects @('*.vw_ActiveUsers')
  Write-TestResult -Name "Wildcard: *.vw_ActiveUsers excludes dbo.vw_ActiveUsers" -Passed ($result -eq $true)

  # Test 5: Wildcard doesn't match unrelated
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'app.Config.sql') -ExcludeObjects @('staging.*')
  Write-TestResult -Name "Wildcard: staging.* does not exclude app.Config" -Passed ($result -eq $false)

  # Test 6: Non-schema-bound folder (Schemas) is never excluded
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $schemasDir 'staging.sql') -ExcludeObjects @('*.*')
  Write-TestResult -Name "Non-schema-bound: Schemas folder not filtered" -Passed ($result -eq $false)

  # Test 7: Empty ExcludeObjects returns false
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'dbo.Users.sql') -ExcludeObjects @()
  Write-TestResult -Name "Empty filter: returns false" -Passed ($result -eq $false)

  # Test 8: Null ExcludeObjects returns false
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'dbo.Users.sql') -ExcludeObjects $null
  Write-TestResult -Name "Null filter: returns false" -Passed ($result -eq $false)

  # Test 9: Numeric prefix handled
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $funcsDir '001_dbo.fn_Grouped.function.sql') -ExcludeObjects @('dbo.fn_Grouped')
  Write-TestResult -Name "Numeric prefix: 001_dbo.fn_Grouped matched" -Passed ($result -eq $true)

  # Test 10: Case-insensitive matching
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'dbo.Users.sql') -ExcludeObjects @('DBO.USERS')
  Write-TestResult -Name "Case-insensitive: DBO.USERS matches dbo.Users" -Passed ($result -eq $true)

  # Test 11: Multiple patterns - first matches
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'dbo.Orders.sql') -ExcludeObjects @('dbo.Users', 'dbo.Orders')
  Write-TestResult -Name "Multiple patterns: second pattern matches" -Passed ($result -eq $true)

  # Test 12: Multiple patterns - none match
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $tablesDir 'app.Config.sql') -ExcludeObjects @('dbo.Users', 'dbo.Orders')
  Write-TestResult -Name "Multiple patterns: none match app.Config" -Passed ($result -eq $false)

  # Test 13: Pattern with partial wildcard
  $result = Test-ObjectExcluded -ScriptPath (Join-Path $procsDir 'dbo.usp_LegacyProc.sql') -ExcludeObjects @('dbo.usp_*')
  Write-TestResult -Name "Partial wildcard: dbo.usp_* matches dbo.usp_LegacyProc" -Passed ($result -eq $true)

  # ═══════════════════════════════════════════════════════════════
  # PHASE 2: Test Get-ScriptFiles filtering with mock directory
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 2] Get-ScriptFiles filtering" -ForegroundColor Yellow

  # We need to extract Get-ScriptFiles too, but it has many dependencies.
  # Instead, simulate the filtering logic directly.
  $allFiles = Get-ChildItem $tempRoot -Recurse -Filter '*.sql' | Where-Object { -not $_.PSIsContainer }

  $excludePatterns = @('dbo.usp_LegacyProc', 'staging.*')
  $filtered = @($allFiles | Where-Object {
      -not (Test-ObjectExcluded -ScriptPath $_.FullName -ExcludeObjects $excludePatterns)
    })

  $excludedCount = $allFiles.Count - $filtered.Count

  # staging.ImportData.sql, staging.vw_RawData.sql, dbo.usp_LegacyProc.sql = 3 excluded
  Write-TestResult -Name "Get-ScriptFiles: correct number excluded (expect 3)" -Passed ($excludedCount -eq 3) -Details "Excluded $excludedCount files"

  # Verify specific files remain
  $remainingNames = $filtered | ForEach-Object { $_.Name }
  Write-TestResult -Name "Get-ScriptFiles: dbo.Users.sql remains" -Passed ($remainingNames -contains 'dbo.Users.sql')
  Write-TestResult -Name "Get-ScriptFiles: app.Config.sql remains" -Passed ($remainingNames -contains 'app.Config.sql')
  Write-TestResult -Name "Get-ScriptFiles: dbo.usp_LegacyProc.sql excluded" -Passed ($remainingNames -notcontains 'dbo.usp_LegacyProc.sql')
  Write-TestResult -Name "Get-ScriptFiles: staging.ImportData.sql excluded" -Passed ($remainingNames -notcontains 'staging.ImportData.sql')
  Write-TestResult -Name "Get-ScriptFiles: staging.sql remains (non-schema-bound Schemas folder)" -Passed ($remainingNames -contains 'staging.sql')

  # ═══════════════════════════════════════════════════════════════
  # PHASE 3: Test CLI parameter sets script variable
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 3] CLI parameter verification" -ForegroundColor Yellow

  # Verify the parameter exists on the script
  $scriptInfo = Get-Command $importScript
  $hasParam = $scriptInfo.Parameters.ContainsKey('ExcludeObjects')
  Write-TestResult -Name "CLI: -ExcludeObjects parameter exists" -Passed $hasParam

  if ($hasParam) {
    $paramInfo = $scriptInfo.Parameters['ExcludeObjects']
    Write-TestResult -Name "CLI: parameter type is string[]" -Passed ($paramInfo.ParameterType.Name -eq 'String[]')
  }

  # ═══════════════════════════════════════════════════════════════
  # PHASE 4: Test config file loading
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 4] Config file validation" -ForegroundColor Yellow

  # Verify excludeObjects is in the JSON schema
  $schemaFile = Join-Path $PSScriptRoot '..' 'export-import-config.schema.json'
  if (Test-Path $schemaFile) {
    $schemaContent = Get-Content $schemaFile -Raw | ConvertFrom-Json
    $importProps = $schemaContent.properties.import.properties
    $hasExcludeObjects = $null -ne $importProps.excludeObjects
    Write-TestResult -Name "Schema: excludeObjects defined in JSON schema" -Passed $hasExcludeObjects

    if ($hasExcludeObjects) {
      Write-TestResult -Name "Schema: type is array" -Passed ($importProps.excludeObjects.type -eq 'array')
      Write-TestResult -Name "Schema: uniqueItems is true" -Passed ($importProps.excludeObjects.uniqueItems -eq $true)
    }
  } else {
    Write-Host "  [SKIP] JSON schema file not found" -ForegroundColor Yellow
  }

  # ═══════════════════════════════════════════════════════════════
  # PHASE 5: Test knownImport validation
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 5] Config key validation" -ForegroundColor Yellow

  # Verify 'excludeObjects' is in the knownImport list
  $knownImportMatch = $scriptContent -match "'excludeObjects'"
  Write-TestResult -Name "Config: 'excludeObjects' in knownImport list" -Passed $knownImportMatch

  # ═══════════════════════════════════════════════════════════════
  # PHASE 6: Test config merge precedence
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 6] Config merge precedence" -ForegroundColor Yellow

  # Verify the script has the config merge block for excludeObjects
  $hasConfigMerge = $scriptContent -match "PSBoundParameters\.ContainsKey\('ExcludeObjects'\)"
  Write-TestResult -Name "Precedence: CLI PSBoundParameters check exists" -Passed $hasConfigMerge

  $hasConfigFallback = $scriptContent -match 'config\.import\.excludeObjects.*Count'
  Write-TestResult -Name "Precedence: config fallback path exists" -Passed $hasConfigFallback

  # Verify config fallback is guarded by CLI check (CLI overrides config)
  # The pattern should be: if (-not $PSBoundParameters.ContainsKey('ExcludeObjects')) { ... config.import.excludeObjects ... }
  $hasGuardedFallback = $scriptContent -match '(?ms)-not \$PSBoundParameters\.ContainsKey\(''ExcludeObjects''\).+?config\.import\.excludeObjects'
  Write-TestResult -Name "Precedence: config fallback guarded by CLI check" -Passed $hasGuardedFallback

  # Verify the CLI registration sets configSources
  $hasCliSource = $scriptContent -match "ConfigSources\.excludeObjects\.source\s*=\s*'cli'"
  Write-TestResult -Name "Precedence: CLI sets ConfigSources.excludeObjects" -Passed $hasCliSource

  $hasConfigSource = $scriptContent -match "ConfigSources\.excludeObjects\s*=\s*\[ordered\]@\{.*source\s*=\s*'configFile'"
  Write-TestResult -Name "Precedence: config sets ConfigSources.excludeObjects" -Passed $hasConfigSource

  # Create a test YAML config and verify it parses correctly
  $testConfigFile = Join-Path $tempRoot 'test-exclude-objects-config.yml'
  @"
import:
  excludeObjects:
    - dbo.usp_LegacyProc
    - staging.*
"@ | Out-File -FilePath $testConfigFile -Encoding utf8

  # Verify the YAML parses and produces the expected structure
  $yamlModule = Get-Module -ListAvailable -Name 'powershell-yaml' | Select-Object -First 1
  if ($yamlModule) {
    Import-Module powershell-yaml -ErrorAction SilentlyContinue
    $testConfig = Get-Content $testConfigFile -Raw | ConvertFrom-Yaml
    $hasObjects = $testConfig.import.excludeObjects -is [System.Collections.IList] -and $testConfig.import.excludeObjects.Count -eq 2
    Write-TestResult -Name "Precedence: YAML config parses excludeObjects array" -Passed $hasObjects
    $correctValues = $testConfig.import.excludeObjects[0] -eq 'dbo.usp_LegacyProc' -and $testConfig.import.excludeObjects[1] -eq 'staging.*'
    Write-TestResult -Name "Precedence: YAML config values are correct" -Passed $correctValues
  } else {
    Write-Host "  [SKIP] powershell-yaml module not available" -ForegroundColor Yellow
  }

} finally {
  # Cleanup temp directory
  if (Test-Path $tempRoot) {
    Remove-Item $tempRoot -Recurse -Force
  }
}

# Summary
Write-Host "`n========================================" -ForegroundColor Cyan
Write-Host "Test Summary: $script:TestsPassed/$script:TestsRun passed" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

if ($script:TestsFailed -gt 0) {
  Write-Host "[FAILED] $script:TestsFailed test(s) failed" -ForegroundColor Red
  exit 1
} else {
  Write-Host "[SUCCESS] All tests passed!" -ForegroundColor Green
  exit 0
}
