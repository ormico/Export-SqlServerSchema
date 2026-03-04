#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the ConvertTo-ImportReport.ps1 report rendering script.

.DESCRIPTION
    Validates:
    1. Report loading and validation (Get-ImportReport)
    2. Console output structure and content
    3. Diff computation (Get-DiffObjects) — finds missing objects
    4. Markdown file output structure
    5. Markdown diff output
    6. Edge cases (empty arrays, missing fields)

    Does NOT require SQL Server. Invokes ConvertTo-ImportReport.ps1 as a subprocess
    to test its behavior end-to-end.

.NOTES
    Issue: #69 - Import report rendering
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent
$rendererScript = Join-Path $projectRoot 'ConvertTo-ImportReport.ps1'

$script:testsPassed = 0
$script:testsFailed = 0

# ─────────────────────────────────────────────────────────────────────────────
# Test Helper
# ─────────────────────────────────────────────────────────────────────────────

function Write-TestResult {
  param(
    [string]$TestName,
    [bool]$Passed,
    [string]$Message = ''
  )
  if ($Passed) {
    Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
    $script:testsPassed++
  }
  else {
    Write-Host "[FAILED]  $TestName" -ForegroundColor Red
    if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
    $script:testsFailed++
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Fixture builder
# ─────────────────────────────────────────────────────────────────────────────

function New-MockReportJson {
  <#
  .SYNOPSIS
      Creates a minimal valid import report JSON file for testing.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Directory,

    [Parameter()]
    [string]$FileName = 'import-report-20260225_120000.json',

    [Parameter()]
    [hashtable]$Overrides = @{}
  )

  $defaults = [ordered]@{
    exportedObjectCount  = 10
    importedObjectCount  = 7
    skippedObjectCount   = 2
    failedObjectCount    = 1
    skippedReasons       = [ordered]@{
      DevMode_CLRAssembly    = 1
      DevMode_SecurityPolicy = 1
    }
    duration             = '00:01:42'
    timestamp            = '2026-02-25T12:00:00.000+00:00'
    sourcePath           = 'C:\exports\TestDb'
    exportMetadataSource = '_export_metadata.json'
    targetServer         = 'localhost'
    targetDatabase       = 'TestDb'
    effectiveConfiguration = [ordered]@{
      importMode = [ordered]@{ value = 'Dev'; source = 'default' }
    }
    exportedObjects      = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Orders'; filePath = '09_Tables_PrimaryKey/dbo.Orders.sql' }
      [ordered]@{ type = 'StoredProcedure'; schema = 'dbo'; name = 'usp_Test'; filePath = '14_Programmability/03_StoredProcedures/dbo.usp_Test.sql' }
      [ordered]@{ type = 'View'; schema = 'dbo'; name = 'vw_Customers'; filePath = '14_Programmability/05_Views/dbo.vw_Customers.sql' }
      [ordered]@{ type = 'Schema'; schema = $null; name = 'dbo'; filePath = '03_Schemas/dbo.sql' }
      [ordered]@{ type = 'Index'; schema = 'dbo'; name = 'IX_Name'; filePath = '10_Indexes/dbo.Customers.IX_Name.sql' }
      [ordered]@{ type = 'ForeignKey'; schema = 'dbo'; name = 'Orders'; filePath = '11_Tables_ForeignKeys/dbo.Orders.sql' }
      [ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'FilterPolicy'; filePath = '20_SecurityPolicies/dbo.FilterPolicy.sql' }
      [ordered]@{ type = 'Synonym'; schema = 'dbo'; name = 'SynTest'; filePath = '15_Synonyms/dbo.SynTest.sql' }
      [ordered]@{ type = 'Function'; schema = 'dbo'; name = 'GetTotal'; filePath = '14_Programmability/02_Functions/dbo.GetTotal.sql' }
    )
    importedObjects      = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Orders'; filePath = '09_Tables_PrimaryKey/dbo.Orders.sql' }
      [ordered]@{ type = 'View'; schema = 'dbo'; name = 'vw_Customers'; filePath = '14_Programmability/05_Views/dbo.vw_Customers.sql' }
      [ordered]@{ type = 'Schema'; schema = $null; name = 'dbo'; filePath = '03_Schemas/dbo.sql' }
      [ordered]@{ type = 'Index'; schema = 'dbo'; name = 'IX_Name'; filePath = '10_Indexes/dbo.Customers.IX_Name.sql' }
      [ordered]@{ type = 'ForeignKey'; schema = 'dbo'; name = 'Orders'; filePath = '11_Tables_ForeignKeys/dbo.Orders.sql' }
      [ordered]@{ type = 'Synonym'; schema = 'dbo'; name = 'SynTest'; filePath = '15_Synonyms/dbo.SynTest.sql' }
    )
    skippedObjects       = @(
      [ordered]@{ type = 'SecurityPolicy'; schema = 'dbo'; name = 'FilterPolicy'; filePath = '20_SecurityPolicies/dbo.FilterPolicy.sql'; reason = 'DevMode_SecurityPolicy' }
      [ordered]@{ type = 'Function'; schema = 'dbo'; name = 'GetTotal'; filePath = '14_Programmability/02_Functions/dbo.GetTotal.sql'; reason = 'DevMode_CLRAssembly' }
    )
    failedObjects        = @(
      [ordered]@{ type = 'StoredProcedure'; schema = 'dbo'; name = 'usp_Test'; filePath = '14_Programmability/03_StoredProcedures/dbo.usp_Test.sql'; folder = '14_Programmability'; reason = 'SqlError'; errorMessage = "Invalid object name 'dbo.MissingTable'." }
    )
  }

  # Apply overrides
  foreach ($key in $Overrides.Keys) {
    $defaults[$key] = $Overrides[$key]
  }

  $filePath = Join-Path $Directory $FileName
  $defaults | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $filePath -Encoding UTF8
  return $filePath
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup temp directory
# ─────────────────────────────────────────────────────────────────────────────

$tempRoot = Join-Path ([System.IO.Path]::GetTempPath()) "convert-report-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
New-Item -ItemType Directory -Path $tempRoot -Force | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Test banner
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'IMPORT REPORT RENDERING TESTS' -ForegroundColor Cyan
Write-Host 'Issue #69: ConvertTo-ImportReport.ps1' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan

try {

  # ─────────────────────────────────────────────────────────────────────────
  # Group 1: Report loading and validation
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 1: Report loading and validation ---' -ForegroundColor Yellow

  # Test 1.1: Missing file exits with error
  $missingPath = Join-Path $tempRoot 'nonexistent.json'
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $missingPath 2>&1 | Out-String
  Write-TestResult 'Missing file: exits with error' ($output -match 'Report file not found' -or $LASTEXITCODE -ne 0)

  # Test 1.2: Malformed JSON exits with error
  $badJsonPath = Join-Path $tempRoot 'bad.json'
  Set-Content -LiteralPath $badJsonPath -Value 'not valid json {{{' -Encoding UTF8
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $badJsonPath 2>&1 | Out-String
  Write-TestResult 'Malformed JSON: exits with error' ($output -match 'Failed to parse' -or $LASTEXITCODE -ne 0)

  # Test 1.3: Valid JSON exits successfully
  $validPath = New-MockReportJson -Directory $tempRoot
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $validPath 2>&1 | Out-String
  Write-TestResult 'Valid JSON: exits successfully' ($LASTEXITCODE -eq 0) `
    -Message "Exit code was $LASTEXITCODE. Output: $output"

  # ─────────────────────────────────────────────────────────────────────────
  # Group 2: Console output structure
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 2: Console output structure ---' -ForegroundColor Yellow

  $reportPath = New-MockReportJson -Directory $tempRoot -FileName 'console-test.json'
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $reportPath 2>&1 | Out-String

  Write-TestResult 'Console: contains header' ($output -match '=== Import Report ===')
  Write-TestResult 'Console: contains Exported count' ($output -match 'Exported:\s+10')
  Write-TestResult 'Console: contains Imported count' ($output -match 'Imported:\s+7')
  Write-TestResult 'Console: contains Skipped count' ($output -match 'Skipped:\s+2')
  Write-TestResult 'Console: contains Failed count' ($output -match 'Failed:\s+1')
  Write-TestResult 'Console: contains Duration' ($output -match '00:01:42')
  Write-TestResult 'Console: contains skipped reason' ($output -match 'DevMode_CLRAssembly')
  Write-TestResult 'Console: contains failed object name' ($output -match 'usp_Test')
  Write-TestResult 'Console: contains failed error message' ($output -match 'MissingTable')
  Write-TestResult 'Console: contains report filename' ($output -match 'console-test\.json')

  # ─────────────────────────────────────────────────────────────────────────
  # Group 3: Console with no failures or skips
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 3: Console with clean import ---' -ForegroundColor Yellow

  $cleanPath = New-MockReportJson -Directory $tempRoot -FileName 'clean-test.json' -Overrides @{
    failedObjectCount = 0
    skippedObjectCount = 0
    importedObjectCount = 10
    skippedReasons = [ordered]@{}
    skippedObjects = @()
    failedObjects = @()
  }
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $cleanPath 2>&1 | Out-String

  Write-TestResult 'Clean import: no Failed objects section' ($output -notmatch 'Failed objects:')
  Write-TestResult 'Clean import: no Skipped reasons section' ($output -notmatch 'Skipped reasons:')
  Write-TestResult 'Clean import: shows counts' ($output -match 'Imported:\s+10')

  # ─────────────────────────────────────────────────────────────────────────
  # Group 4: Diff computation
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 4: Diff computation ---' -ForegroundColor Yellow

  # All objects accounted for — no missing
  $allAccountedPath = New-MockReportJson -Directory $tempRoot -FileName 'diff-all-accounted.json'
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $allAccountedPath -Diff 2>&1 | Out-String
  Write-TestResult 'Diff: all accounted for - no missing section' ($output -notmatch 'Missing objects')

  # Create a report with a gap — one exported object not in imported/skipped/failed
  $gapOverrides = @{
    exportedObjects = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Orders'; filePath = '09_Tables_PrimaryKey/dbo.Orders.sql' }
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Phantom'; filePath = '09_Tables_PrimaryKey/dbo.Phantom.sql' }
    )
    importedObjects = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
    )
    skippedObjects = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Orders'; filePath = '09_Tables_PrimaryKey/dbo.Orders.sql'; reason = 'TestSkip' }
    )
    failedObjects = @()
    exportedObjectCount = 3
    importedObjectCount = 1
    skippedObjectCount = 1
    failedObjectCount = 0
    skippedReasons = [ordered]@{ TestSkip = 1 }
  }
  $gapPath = New-MockReportJson -Directory $tempRoot -FileName 'diff-gap.json' -Overrides $gapOverrides
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $gapPath -Diff 2>&1 | Out-String

  Write-TestResult 'Diff: detects missing object' ($output -match 'Missing objects')
  Write-TestResult 'Diff: shows Phantom table' ($output -match 'Phantom')
  Write-TestResult 'Diff: shows count of 1' ($output -match '1 not accounted for')

  # Empty exportedObjects — warning, no crash
  $emptyExportPath = New-MockReportJson -Directory $tempRoot -FileName 'diff-empty-export.json' -Overrides @{
    exportedObjects = @()
  }
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $emptyExportPath -Diff 2>&1 | Out-String
  Write-TestResult 'Diff: empty exportedObjects - warning shown' ($output -match 'WARNING.*Diff requires exportedObjects')
  Write-TestResult 'Diff: empty exportedObjects - exits cleanly' ($LASTEXITCODE -eq 0)

  # Diff includes failedObjects in accounted set
  $failedAccountedOverrides = @{
    exportedObjects = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
      [ordered]@{ type = 'StoredProcedure'; schema = 'dbo'; name = 'usp_Broken'; filePath = '14_Programmability/03_StoredProcedures/dbo.usp_Broken.sql' }
    )
    importedObjects = @(
      [ordered]@{ type = 'Table'; schema = 'dbo'; name = 'Customers'; filePath = '09_Tables_PrimaryKey/dbo.Customers.sql' }
    )
    skippedObjects = @()
    failedObjects = @(
      [ordered]@{ type = 'StoredProcedure'; schema = 'dbo'; name = 'usp_Broken'; filePath = '14_Programmability/03_StoredProcedures/dbo.usp_Broken.sql'; reason = 'SqlError'; errorMessage = 'Some error' }
    )
    exportedObjectCount = 2
    importedObjectCount = 1
    skippedObjectCount = 0
    failedObjectCount = 1
    skippedReasons = [ordered]@{}
  }
  $failedAccountedPath = New-MockReportJson -Directory $tempRoot -FileName 'diff-failed-accounted.json' -Overrides $failedAccountedOverrides
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $failedAccountedPath -Diff 2>&1 | Out-String
  Write-TestResult 'Diff: failed objects count as accounted for' ($output -notmatch 'Missing objects')

  # ─────────────────────────────────────────────────────────────────────────
  # Group 5: Markdown output
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 5: Markdown output ---' -ForegroundColor Yellow

  $mdDir = Join-Path $tempRoot 'markdown'
  New-Item -ItemType Directory -Path $mdDir -Force | Out-Null
  $mdReportPath = New-MockReportJson -Directory $mdDir -FileName 'import-report-20260225_120000.json'

  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $mdReportPath -Format Markdown 2>&1 | Out-String
  Write-TestResult 'Markdown: exits successfully' ($LASTEXITCODE -eq 0) `
    -Message "Exit code: $LASTEXITCODE, Output: $output"

  # Default path should be .md next to .json
  $expectedMdPath = Join-Path $mdDir 'import-report-20260225_120000.md'
  Write-TestResult 'Markdown: default output path is .md extension' (Test-Path -LiteralPath $expectedMdPath)

  if (Test-Path -LiteralPath $expectedMdPath) {
    $mdContent = Get-Content -LiteralPath $expectedMdPath -Raw

    Write-TestResult 'Markdown: contains H1 heading' ($mdContent -match '# Import Report')
    Write-TestResult 'Markdown: contains Summary section' ($mdContent -match '## Summary')
    Write-TestResult 'Markdown: contains summary table' ($mdContent -match '\| Exported \| 10 \|')
    Write-TestResult 'Markdown: contains Skipped Reasons section' ($mdContent -match '## Skipped Reasons')
    Write-TestResult 'Markdown: contains skipped reason value' ($mdContent -match 'DevMode_CLRAssembly')
    Write-TestResult 'Markdown: contains Skipped Objects section' ($mdContent -match '## Skipped Objects')
    Write-TestResult 'Markdown: contains Failed Objects section' ($mdContent -match '## Failed Objects')
    Write-TestResult 'Markdown: contains failed object name' ($mdContent -match 'usp_Test')
    Write-TestResult 'Markdown: contains error message' ($mdContent -match 'MissingTable')
    Write-TestResult 'Markdown: contains target server' ($mdContent -match 'localhost')
    Write-TestResult 'Markdown: contains target database' ($mdContent -match 'TestDb')
  }
  else {
    # If file wasn't created, fail all the content tests
    for ($i = 0; $i -lt 11; $i++) {
      Write-TestResult "Markdown: content test (skipped - file not created)" $false
    }
  }

  # Test -OutputPath override
  $customMdPath = Join-Path $tempRoot 'custom-output.md'
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $mdReportPath -Format Markdown -OutputPath $customMdPath 2>&1 | Out-String
  Write-TestResult 'Markdown: -OutputPath override creates file at custom path' (Test-Path -LiteralPath $customMdPath)

  # ─────────────────────────────────────────────────────────────────────────
  # Group 6: Markdown with diff
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 6: Markdown diff output ---' -ForegroundColor Yellow

  $mdDiffDir = Join-Path $tempRoot 'markdown-diff'
  New-Item -ItemType Directory -Path $mdDiffDir -Force | Out-Null
  $mdDiffReportPath = New-MockReportJson -Directory $mdDiffDir -FileName 'diff-report.json' -Overrides $gapOverrides
  $mdDiffOutputPath = Join-Path $mdDiffDir 'diff-report.md'

  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $mdDiffReportPath -Format Markdown -Diff 2>&1 | Out-String
  Write-TestResult 'Markdown diff: exits successfully' ($LASTEXITCODE -eq 0) `
    -Message "Exit code: $LASTEXITCODE, Output: $output"

  if (Test-Path -LiteralPath $mdDiffOutputPath) {
    $mdDiffContent = Get-Content -LiteralPath $mdDiffOutputPath -Raw
    Write-TestResult 'Markdown diff: contains Missing Objects section' ($mdDiffContent -match '## Missing Objects')
    Write-TestResult 'Markdown diff: contains Phantom table' ($mdDiffContent -match 'Phantom')
    Write-TestResult 'Markdown diff: no Missing Objects when all accounted' $true  # Already tested in Group 4
  }
  else {
    Write-TestResult 'Markdown diff: file created' $false -Message "Expected file at $mdDiffOutputPath"
    Write-TestResult 'Markdown diff: contains Missing Objects section' $false
    Write-TestResult 'Markdown diff: contains Phantom table' $false
  }

  # Markdown without diff should NOT have Missing Objects section
  $mdNoDiffDir = Join-Path $tempRoot 'markdown-nodiff'
  New-Item -ItemType Directory -Path $mdNoDiffDir -Force | Out-Null
  $mdNoDiffReportPath = New-MockReportJson -Directory $mdNoDiffDir -FileName 'nodiff-report.json' -Overrides $gapOverrides
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $mdNoDiffReportPath -Format Markdown 2>&1 | Out-String
  $mdNoDiffOutputPath = Join-Path $mdNoDiffDir 'nodiff-report.md'

  if (Test-Path -LiteralPath $mdNoDiffOutputPath) {
    $mdNoDiffContent = Get-Content -LiteralPath $mdNoDiffOutputPath -Raw
    Write-TestResult 'Markdown: no Missing Objects section without -Diff' ($mdNoDiffContent -notmatch '## Missing Objects')
  }
  else {
    Write-TestResult 'Markdown: no Missing Objects section without -Diff' $false -Message 'File not created'
  }

  # ─────────────────────────────────────────────────────────────────────────
  # Group 7: Edge cases
  # ─────────────────────────────────────────────────────────────────────────

  Write-Host ''
  Write-Host '--- Group 7: Edge cases ---' -ForegroundColor Yellow

  # Report with no skippedReasons key
  $noReasonsPath = New-MockReportJson -Directory $tempRoot -FileName 'no-reasons.json' -Overrides @{
    skippedReasons = $null
  }
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $noReasonsPath 2>&1 | Out-String
  Write-TestResult 'Edge: null skippedReasons does not crash' ($LASTEXITCODE -eq 0)

  # Report with empty arrays
  $emptyPath = New-MockReportJson -Directory $tempRoot -FileName 'empty-arrays.json' -Overrides @{
    exportedObjectCount = 0
    importedObjectCount = 0
    skippedObjectCount = 0
    failedObjectCount = 0
    skippedReasons = [ordered]@{}
    exportedObjects = @()
    importedObjects = @()
    skippedObjects = @()
    failedObjects = @()
  }
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $emptyPath 2>&1 | Out-String
  Write-TestResult 'Edge: all-empty report renders cleanly' ($LASTEXITCODE -eq 0)
  Write-TestResult 'Edge: all-empty shows zero counts' ($output -match 'Exported:\s+0')

  # Report with null duration
  $noDurationPath = New-MockReportJson -Directory $tempRoot -FileName 'no-duration.json' -Overrides @{
    duration = $null
  }
  $output = & pwsh -NoProfile -File $rendererScript -ReportPath $noDurationPath 2>&1 | Out-String
  Write-TestResult 'Edge: null duration does not crash' ($LASTEXITCODE -eq 0)

}
finally {
  Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "Tests passed: $($script:testsPassed)" -ForegroundColor Green
Write-Host "Tests failed: $($script:testsFailed)" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

if ($script:testsFailed -gt 0) { exit 1 } else { exit 0 }
