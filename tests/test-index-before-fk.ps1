#Requires -Version 7.0

<#
.SYNOPSIS
    Tests that indexes are ordered before foreign keys in export/import.

.DESCRIPTION
    Validates the fix for issue #93: standalone unique indexes must be created
    before foreign key constraints that reference them. Checks:
    1. Export folder structure places 10_Indexes before 11_Tables_ForeignKeys
    2. Import script processes indexes before foreign keys
    3. Folder-to-type mappings use correct folder names

.NOTES
    Issue: #93 - Unique indexes should load before foreign key constraints
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

# ── Test framework helpers ──────────────────────────────────────────────────

$script:totalTests = 0
$script:passedTests = 0
$script:failedTests = 0

function Write-TestResult {
  param([string]$Name, [bool]$Passed, [string]$Detail = '')
  $script:totalTests++
  if ($Passed) {
    $script:passedTests++
    Write-Host "  [PASS] $Name" -ForegroundColor Green
  } else {
    $script:failedTests++
    $msg = "  [FAIL] $Name"
    if ($Detail) { $msg += " - $Detail" }
    Write-Host $msg -ForegroundColor Red
  }
}

function Write-TestInfo {
  param([string]$Message)
  Write-Host "  $Message" -ForegroundColor Cyan
}

# ── Test 1: Export script folder order ──────────────────────────────────────

Write-Host "`n=== Test 1: Export script Initialize-OutputDirectory folder order ===" -ForegroundColor Yellow

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$exportContent = Get-Content $exportScript -Raw

# Extract the Initialize-OutputDirectory folder array section
# Look for the array that lists all numbered folders in order
$initSection = [regex]::Match($exportContent, 'function Initialize-OutputDirectory[\s\S]*?(?=\nfunction )')
$initText = $initSection.Value
$indexFolderPos = $initText.IndexOf("'10_Indexes'")
$fkFolderPos = $initText.IndexOf("'11_Tables_ForeignKeys'")

Write-TestResult 'Export: 10_Indexes folder exists in Initialize-OutputDirectory' ($indexFolderPos -gt 0)
Write-TestResult 'Export: 11_Tables_ForeignKeys folder exists in Initialize-OutputDirectory' ($fkFolderPos -gt 0)
Write-TestResult 'Export: 10_Indexes appears before 11_Tables_ForeignKeys' ($indexFolderPos -lt $fkFolderPos)

# Verify old folder names are gone
$oldFkFolder = $exportContent.Contains("'10_Tables_ForeignKeys'")
$oldIdxFolder = $exportContent.Contains("'11_Indexes'")
Write-TestResult 'Export: no legacy 10_Tables_ForeignKeys references' (-not $oldFkFolder)
Write-TestResult 'Export: no legacy 11_Indexes references' (-not $oldIdxFolder)

# ── Test 2: Export script folder-to-type mapping ────────────────────────────

Write-Host "`n=== Test 2: Export script folder-to-type mapping ===" -ForegroundColor Yellow

$hasIndexMapping = $exportContent -match "'10_Indexes'\s*=\s*'Index'"
$hasFkMapping = $exportContent -match "'11_Tables_ForeignKeys'\s*=\s*'ForeignKey'"
Write-TestResult 'Export: 10_Indexes maps to Index' $hasIndexMapping
Write-TestResult 'Export: 11_Tables_ForeignKeys maps to ForeignKey' $hasFkMapping

# ── Test 3: Export script Build-ParallelWorkQueue order ─────────────────────

Write-Host "`n=== Test 3: Export script work queue order ===" -ForegroundColor Yellow

# Extract the Build-ParallelWorkQueue function to check call order within it
$queueSection = [regex]::Match($exportContent, 'function Build-ParallelWorkQueue[\s\S]*?(?=\nfunction )')
$queueText = $queueSection.Value
$indexWorkPos = $queueText.IndexOf('Build-WorkItems-Indexes')
$fkWorkPos = $queueText.IndexOf('Build-WorkItems-ForeignKeys')
Write-TestResult 'Export: Build-WorkItems-Indexes before Build-WorkItems-ForeignKeys in queue' ($indexWorkPos -lt $fkWorkPos)

# ── Test 4: Export script objectTypeOrder ────────────────────────────────────

Write-Host "`n=== Test 4: Export script objectTypeOrder ===" -ForegroundColor Yellow

$hasCorrectOrder = $exportContent -match "'Index',\s*'ForeignKey'"
Write-TestResult 'Export: objectTypeOrder has Index before ForeignKey' $hasCorrectOrder

# ── Test 5: Export script deployment manifest ────────────────────────────────

Write-Host "`n=== Test 5: Export script deployment manifest ===" -ForegroundColor Yellow

$hasManifestIdx = $exportContent -match '10\.\s*10_Indexes\s*-\s*Create indexes'
$hasManifestFk = $exportContent -match '11\.\s*11_Tables_ForeignKeys\s*-\s*Add foreign key constraints'
Write-TestResult 'Export: manifest entry 10 is Indexes' $hasManifestIdx
Write-TestResult 'Export: manifest entry 11 is ForeignKeys' $hasManifestFk

# ── Test 6: Import script folder-to-type mapping ────────────────────────────

Write-Host "`n=== Test 6: Import script folder-to-type mapping ===" -ForegroundColor Yellow

$importScript = Join-Path $projectRoot 'Import-SqlServerSchema.ps1'
$importContent = Get-Content $importScript -Raw

$hasImportIdxMapping = $importContent -match "'10_Indexes'\s*=\s*'Index'"
$hasImportFkMapping = $importContent -match "'11_Tables_ForeignKeys'\s*=\s*'ForeignKey'"
Write-TestResult 'Import: 10_Indexes maps to Index' $hasImportIdxMapping
Write-TestResult 'Import: 11_Tables_ForeignKeys maps to ForeignKey' $hasImportFkMapping

# Verify old folder names are gone
$oldImportFk = $importContent.Contains("'10_Tables_ForeignKeys'")
$oldImportIdx = $importContent.Contains("'11_Indexes'")
Write-TestResult 'Import: no legacy 10_Tables_ForeignKeys references' (-not $oldImportFk)
Write-TestResult 'Import: no legacy 11_Indexes references' (-not $oldImportIdx)

# ── Test 7: Import script Get-ScriptFiles ordered dirs ──────────────────────

Write-Host "`n=== Test 7: Import script Get-ScriptFiles ordering ===" -ForegroundColor Yellow

$importIdxPos = $importContent.IndexOf("'10_Indexes',")
$importFkPos = $importContent.IndexOf("'11_Tables_ForeignKeys',")
Write-TestResult 'Import: 10_Indexes in ordered dirs' ($importIdxPos -gt 0)
Write-TestResult 'Import: 11_Tables_ForeignKeys in ordered dirs' ($importFkPos -gt 0)
Write-TestResult 'Import: 10_Indexes before 11_Tables_ForeignKeys in ordered dirs' ($importIdxPos -lt $importFkPos)

# ── Test 8: Import script Test-FolderNameMatch patterns ─────────────────────

Write-Host "`n=== Test 8: Import script Test-FolderNameMatch patterns ===" -ForegroundColor Yellow

$hasIdxPattern = $importContent -match "10_Indexes"
$hasFkPattern = $importContent -match "11_Tables.*ForeignKeys"
Write-TestResult 'Import: Test-FolderNameMatch references 10_Indexes' $hasIdxPattern
Write-TestResult 'Import: Test-FolderNameMatch references 11_Tables_ForeignKeys' $hasFkPattern

# ── Test 9: Import script FK disable path ────────────────────────────────────

Write-Host "`n=== Test 9: Import script FK disable folder check ===" -ForegroundColor Yellow

$hasFkDisable = $importContent -match "11_Tables_ForeignKeys"
Write-TestResult 'Import: FK disable references 11_Tables_ForeignKeys' $hasFkDisable

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n=== Summary ===" -ForegroundColor Yellow
Write-Host "  Total: $script:totalTests  Passed: $script:passedTests  Failed: $script:failedTests"

if ($script:failedTests -gt 0) {
  Write-Host "`n  SOME TESTS FAILED" -ForegroundColor Red
  exit 1
} else {
  Write-Host "`n  ALL TESTS PASSED" -ForegroundColor Green
  exit 0
}
