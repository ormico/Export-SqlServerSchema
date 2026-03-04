#Requires -Version 7.0

<#
.SYNOPSIS
    Tests that schema-bound folder matching uses prefix matching, not substring matching.

.DESCRIPTION
    Regression tests for issue #112: Test-SchemaExcluded and Test-ObjectExcluded used
    -match (regex substring matching) which caused false positives — e.g.,
    'DatabaseConfiguration' matched 'Data'. The fix strips numeric prefixes and uses
    -like with a trailing wildcard for safe substring-start matching.
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
Write-Host "Schema-Bound Folder Matching Test (#112)" -ForegroundColor Cyan
Write-Host "========================================`n" -ForegroundColor Cyan

# ── Load import filter helpers ──
$importHelpers = Join-Path $PSScriptRoot '..' 'Import-Helpers.ps1'
if (-not (Test-Path $importHelpers)) {
  Write-Host "[ERROR] Import-Helpers.ps1 not found at $importHelpers" -ForegroundColor Red
  exit 1
}
. $importHelpers

# Create temp directory structure
$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "FolderMatchTest_$(Get-Random)"

# Folders WITH numeric prefixes (realistic layout)
$dirs = @(
  (Join-Path $tempRoot '09_Tables'),
  (Join-Path $tempRoot '09_Tables_PrimaryKey'),
  (Join-Path $tempRoot '11_Tables_ForeignKeys'),
  (Join-Path $tempRoot '10_Indexes'),
  (Join-Path $tempRoot '05_Views'),
  (Join-Path $tempRoot '02_Functions'),
  (Join-Path $tempRoot '03_StoredProcedures'),
  (Join-Path $tempRoot '04_Triggers'),
  (Join-Path $tempRoot '15_Synonyms'),
  (Join-Path $tempRoot '04_Sequences'),
  (Join-Path $tempRoot '07_Types'),
  (Join-Path $tempRoot '08_XmlSchemaCollections'),
  (Join-Path $tempRoot '12_Defaults'),
  (Join-Path $tempRoot '13_Rules'),
  (Join-Path $tempRoot '21_Data'),
  # Non-schema-bound folders
  (Join-Path $tempRoot '02_DatabaseConfiguration'),
  (Join-Path $tempRoot '01_Security'),
  (Join-Path $tempRoot '03_Schemas'),
  # False-positive traps
  (Join-Path $tempRoot 'ExternalData'),
  (Join-Path $tempRoot 'DataWarehouse')
)

foreach ($d in $dirs) {
  New-Item -ItemType Directory -Path $d -Force | Out-Null
}

# Create mock SQL files in each directory
foreach ($d in $dirs) {
  'SELECT 1;' | Out-File -FilePath (Join-Path $d 'dbo.TestObj.sql') -Encoding utf8
}

try {
  # ═══════════════════════════════════════════════════════════════
  # PHASE 1: Test-SchemaExcluded — schema-bound folders match correctly
  # ═══════════════════════════════════════════════════════════════
  Write-Host "[PHASE 1] Test-SchemaExcluded: schema-bound folders match correctly" -ForegroundColor Yellow

  $schemaBoundDirs = @(
    '09_Tables', '09_Tables_PrimaryKey', '11_Tables_ForeignKeys',
    '10_Indexes', '05_Views', '02_Functions', '03_StoredProcedures',
    '04_Triggers', '15_Synonyms', '04_Sequences',
    '07_Types', '08_XmlSchemaCollections', '12_Defaults', '13_Rules',
    '21_Data'
  )

  foreach ($dir in $schemaBoundDirs) {
    $path = Join-Path $tempRoot $dir 'dbo.TestObj.sql'
    $result = Test-SchemaExcluded -ScriptPath $path -ExcludeSchemas @('dbo')
    Write-TestResult -Name "SchemaExcluded: $dir recognized as schema-bound" -Passed ($result -eq $true)
  }

  # ═══════════════════════════════════════════════════════════════
  # PHASE 2: Test-SchemaExcluded — non-schema-bound folders do NOT match
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 2] Test-SchemaExcluded: non-schema-bound folders do NOT match" -ForegroundColor Yellow

  $nonSchemaBoundDirs = @(
    '02_DatabaseConfiguration', '01_Security', '03_Schemas'
  )

  foreach ($dir in $nonSchemaBoundDirs) {
    $path = Join-Path $tempRoot $dir 'dbo.TestObj.sql'
    $result = Test-SchemaExcluded -ScriptPath $path -ExcludeSchemas @('dbo')
    Write-TestResult -Name "SchemaExcluded: $dir NOT schema-bound" -Passed ($result -eq $false)
  }

  # ═══════════════════════════════════════════════════════════════
  # PHASE 3: False positive regression — substring must NOT match
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 3] False positive regression tests" -ForegroundColor Yellow

  # DatabaseConfiguration should NOT match 'Data'
  $path = Join-Path $tempRoot '02_DatabaseConfiguration' 'dbo.TestObj.sql'
  $result = Test-SchemaExcluded -ScriptPath $path -ExcludeSchemas @('dbo')
  Write-TestResult -Name "False positive: DatabaseConfiguration does NOT match Data" -Passed ($result -eq $false)

  # ExternalData should NOT match 'Data' (no numeric prefix)
  $path = Join-Path $tempRoot 'ExternalData' 'dbo.TestObj.sql'
  $result = Test-SchemaExcluded -ScriptPath $path -ExcludeSchemas @('dbo')
  Write-TestResult -Name "False positive: ExternalData does NOT match Data" -Passed ($result -eq $false)

  # DataWarehouse should NOT match 'Data' (no numeric prefix)
  $path = Join-Path $tempRoot 'DataWarehouse' 'dbo.TestObj.sql'
  $result = Test-SchemaExcluded -ScriptPath $path -ExcludeSchemas @('dbo')
  Write-TestResult -Name "False positive: DataWarehouse does NOT match Data" -Passed ($result -eq $false)

  # ═══════════════════════════════════════════════════════════════
  # PHASE 4: Test-ObjectExcluded — same folder matching logic
  # ═══════════════════════════════════════════════════════════════
  Write-Host "`n[PHASE 4] Test-ObjectExcluded: folder matching logic" -ForegroundColor Yellow

  # Schema-bound folders should be recognized
  foreach ($dir in @('09_Tables', '07_Types', '08_XmlSchemaCollections', '12_Defaults', '13_Rules', '21_Data')) {
    $path = Join-Path $tempRoot $dir 'dbo.TestObj.sql'
    $result = Test-ObjectExcluded -ScriptPath $path -ExcludeObjects @('dbo.TestObj')
    Write-TestResult -Name "ObjectExcluded: $dir recognized as schema-bound" -Passed ($result -eq $true)
  }

  # Non-schema-bound folders should NOT filter
  $path = Join-Path $tempRoot '02_DatabaseConfiguration' 'dbo.TestObj.sql'
  $result = Test-ObjectExcluded -ScriptPath $path -ExcludeObjects @('dbo.TestObj')
  Write-TestResult -Name "ObjectExcluded: DatabaseConfiguration NOT schema-bound" -Passed ($result -eq $false)

  # False positive: ExternalData should NOT match Data
  $path = Join-Path $tempRoot 'ExternalData' 'dbo.TestObj.sql'
  $result = Test-ObjectExcluded -ScriptPath $path -ExcludeObjects @('dbo.TestObj')
  Write-TestResult -Name "ObjectExcluded: ExternalData does NOT match Data" -Passed ($result -eq $false)

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
