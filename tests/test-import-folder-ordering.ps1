#Requires -Version 7.0

<#
.SYNOPSIS
    Tests import-aware folder ordering (issue #98).

.DESCRIPTION
    Validates the implementation of type-based import ordering:
    1. Export metadata v1.2 format (folderOrder, exportToolVersion)
    2. Canonical type order mapping in import
    3. Fallback parsing for old exports without folderOrder
    4. Type-based reordering with warning emission
    5. Backward compatibility (new import + old metadata)

.NOTES
    Issue: #98 - Import-aware folder ordering
#>
# TestType: unit

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
  }
  else {
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

# ── Load script content ─────────────────────────────────────────────────────

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$importScript = Join-Path $projectRoot 'Import-SqlServerSchema.ps1'
$commonScript = Join-Path $projectRoot 'Common-SqlServerSchema.ps1'

$exportContent = Get-Content $exportScript -Raw
$importContent = Get-Content $importScript -Raw

# Dot-source Common to get Resolve-FolderTypeFromName for real function testing
. $commonScript

# ── Test 1: Export metadata version bumped to 1.2 ──────────────────────────

Write-Host "`n=== Test 1: Export metadata version ===" -ForegroundColor Yellow

$hasVersion12 = $exportContent -match "Version\s*=\s*'1\.2'"
Write-TestResult 'Export: metadata version is 1.2' $hasVersion12

# ── Test 2: Export tool version constant ────────────────────────────────────

Write-Host "`n=== Test 2: Export tool version constant ===" -ForegroundColor Yellow

$hasToolVersion = $exportContent -match '\$script:ExportToolVersion\s*=\s*'''
Write-TestResult 'Export: $script:ExportToolVersion constant exists' $hasToolVersion

# ── Test 3: Save-ExportMetadata includes folderOrder ────────────────────────

Write-Host "`n=== Test 3: Save-ExportMetadata folderOrder field ===" -ForegroundColor Yellow

# Extract Save-ExportMetadata function
$saveMetaSection = [regex]::Match($exportContent, 'function Save-ExportMetadata[\s\S]*?(?=\nfunction |\n\z)')
$saveMetaText = $saveMetaSection.Value

$hasFolderOrderField = $saveMetaText -match 'folderOrder\s*='
Write-TestResult 'Export: Save-ExportMetadata writes folderOrder' $hasFolderOrderField

$hasExportToolVersionField = $saveMetaText -match 'exportToolVersion\s*='
Write-TestResult 'Export: Save-ExportMetadata writes exportToolVersion' $hasExportToolVersionField

# ── Test 4: folderOrder contains all 22 folder type mappings ────────────────

Write-Host "`n=== Test 4: folderOrder type ID mappings ===" -ForegroundColor Yellow

$expectedTypes = @(
  'filegroups', 'security', 'security_role_members', 'database_configuration', 'schemas', 'sequences',
  'partition_functions', 'partition_schemes', 'types', 'xml_schema_collections',
  'tables_primarykey', 'indexes', 'tables_foreignkeys', 'defaults', 'rules',
  'programmability', 'synonyms', 'fulltext_search', 'external_data',
  'search_property_lists', 'plan_guides', 'security_policies', 'data'
)

foreach ($type in $expectedTypes) {
  $hasType = $saveMetaText -match "'$type'"
  Write-TestResult "Export: folderOrder contains type '$type'" $hasType
}

# ── Test 5: folderOrder folder-to-type pairings are correct ─────────────────

Write-Host "`n=== Test 5: folderOrder folder-to-type pairings ===" -ForegroundColor Yellow

$pairings = @{
  '00_FileGroups'            = 'filegroups'
  '01_Security_RoleMembers'  = 'security_role_members'
  '09_Tables_PrimaryKey'     = 'tables_primarykey'
  '10_Indexes'               = 'indexes'
  '11_Tables_ForeignKeys'    = 'tables_foreignkeys'
  '14_Programmability'       = 'programmability'
  '21_Data'                  = 'data'
}

foreach ($folder in $pairings.Keys) {
  $type = $pairings[$folder]
  # Check that the folder and type appear in close proximity (same map entry)
  $hasMapping = $saveMetaText -match "'$folder'\s*=\s*'$type'"
  Write-TestResult "Export: $folder maps to $type" $hasMapping
}

# ── Test 6: Import - Get-CanonicalTypeOrder function exists ─────────────────

Write-Host "`n=== Test 6: Import - Get-CanonicalTypeOrder ===" -ForegroundColor Yellow

$hasCanonicalFn = $importContent -match 'function Get-CanonicalTypeOrder'
Write-TestResult 'Import: Get-CanonicalTypeOrder function exists' $hasCanonicalFn

# Verify it returns all 22 type identifiers
foreach ($type in $expectedTypes) {
  $hasType = $importContent -match "'$type'\s*=\s*\d+"
  Write-TestResult "Import: canonical order contains type '$type'" $hasType
}

# ── Test 7: Canonical ordering places indexes before foreign keys ───────────

Write-Host "`n=== Test 7: Import canonical order - indexes before FK ===" -ForegroundColor Yellow

# Extract the Get-CanonicalTypeOrder function
$canonicalSection = [regex]::Match($importContent, 'function Get-CanonicalTypeOrder[\s\S]*?(?=\nfunction )')
$canonicalText = $canonicalSection.Value

$indexesMatch = [regex]::Match($canonicalText, "'indexes'\s*=\s*(\d+)")
$fkMatch = [regex]::Match($canonicalText, "'tables_foreignkeys'\s*=\s*(\d+)")

$indexesOrder = if ($indexesMatch.Success) { [int]$indexesMatch.Groups[1].Value } else { -1 }
$fkOrder = if ($fkMatch.Success) { [int]$fkMatch.Groups[1].Value } else { -1 }

Write-TestResult 'Import: indexes order value found' ($indexesOrder -ge 0)
Write-TestResult 'Import: tables_foreignkeys order value found' ($fkOrder -ge 0)
Write-TestResult 'Import: indexes before tables_foreignkeys in canonical order' ($indexesOrder -lt $fkOrder)

# ── Test 7b: security_role_members after security, before database_configuration ──

Write-Host "`n=== Test 7b: security_role_members ordering ===" -ForegroundColor Yellow

$secMatch    = [regex]::Match($canonicalText, "'security'\s*=\s*(\d+)")
$rolMemMatch = [regex]::Match($canonicalText, "'security_role_members'\s*=\s*(\d+)")
$dbCfgMatch  = [regex]::Match($canonicalText, "'database_configuration'\s*=\s*(\d+)")

$secOrder    = if ($secMatch.Success)    { [int]$secMatch.Groups[1].Value }    else { -1 }
$rolMemOrder = if ($rolMemMatch.Success) { [int]$rolMemMatch.Groups[1].Value } else { -1 }
$dbCfgOrder  = if ($dbCfgMatch.Success)  { [int]$dbCfgMatch.Groups[1].Value }  else { -1 }

Write-TestResult 'Import: security_role_members in canonical order' ($rolMemOrder -ge 0)
Write-TestResult 'Import: security_role_members after security' ($secOrder -lt $rolMemOrder)
Write-TestResult 'Import: security_role_members before database_configuration' ($rolMemOrder -lt $dbCfgOrder)

# ── Test 8: Resolve-FolderTypeFromName function ─────────────────────────────

Write-Host "`n=== Test 8: Common - Resolve-FolderTypeFromName ===" -ForegroundColor Yellow

$commonContent = Get-Content $commonScript -Raw
$hasResolveFn = $commonContent -match 'function Resolve-FolderTypeFromName'
Write-TestResult 'Common: Resolve-FolderTypeFromName function exists' $hasResolveFn

# Test the real function (dot-sourced from Common) with all canonical type IDs
$testCases = @{
  '00_FileGroups'            = 'filegroups'
  '01_Security'              = 'security'
  '01_Security_RoleMembers'  = 'security_role_members'
  '02_DatabaseConfiguration' = 'database_configuration'
  '03_Schemas'               = 'schemas'
  '04_Sequences'             = 'sequences'
  '05_PartitionFunctions'    = 'partition_functions'
  '06_PartitionSchemes'      = 'partition_schemes'
  '07_Types'                 = 'types'
  '08_XmlSchemaCollections'  = 'xml_schema_collections'
  '09_Tables_PrimaryKey'     = 'tables_primarykey'
  '10_Indexes'               = 'indexes'
  '11_Tables_ForeignKeys'    = 'tables_foreignkeys'
  '12_Defaults'              = 'defaults'
  '13_Rules'                 = 'rules'
  '14_Programmability'       = 'programmability'
  '15_Synonyms'              = 'synonyms'
  '16_FullTextSearch'        = 'fulltext_search'
  '17_ExternalData'          = 'external_data'
  '18_SearchPropertyLists'   = 'search_property_lists'
  '19_PlanGuides'            = 'plan_guides'
  '20_SecurityPolicies'      = 'security_policies'
  '21_Data'                  = 'data'
}

foreach ($folder in $testCases.Keys) {
  $expected = $testCases[$folder]
  $actual = Resolve-FolderTypeFromName -FolderName $folder
  Write-TestResult "Resolve: '$folder' -> '$expected'" ($actual -eq $expected) $(if ($actual -ne $expected) { "got '$actual'" }  )
}

# ── Test 9: Get-TypeBasedFolderOrder function ───────────────────────────────

Write-Host "`n=== Test 9: Import - Get-TypeBasedFolderOrder ===" -ForegroundColor Yellow

$hasReorderFn = $importContent -match 'function Get-TypeBasedFolderOrder'
Write-TestResult 'Import: Get-TypeBasedFolderOrder function exists' $hasReorderFn

# Verify it reads metadata
$hasReadMetadata = [regex]::Match($importContent, 'function Get-TypeBasedFolderOrder[\s\S]*?(?=\nfunction )').Value -match 'Read-ExportMetadata'
Write-TestResult 'Import: Get-TypeBasedFolderOrder calls Read-ExportMetadata' $hasReadMetadata

# Verify it uses canonical order
$hasCanonicalUse = [regex]::Match($importContent, 'function Get-TypeBasedFolderOrder[\s\S]*?(?=\nfunction )').Value -match 'Get-CanonicalTypeOrder'
Write-TestResult 'Import: Get-TypeBasedFolderOrder uses Get-CanonicalTypeOrder' $hasCanonicalUse

# ── Test 10: Get-ScriptFiles uses type-based ordering ───────────────────────

Write-Host "`n=== Test 10: Get-ScriptFiles integration ===" -ForegroundColor Yellow

$scriptFilesSection = [regex]::Match($importContent, 'function Get-ScriptFiles[\s\S]*?(?=\nfunction )')
$scriptFilesText = $scriptFilesSection.Value

$hasReorderCall = $scriptFilesText -match 'Get-TypeBasedFolderOrder'
Write-TestResult 'Import: Get-ScriptFiles calls Get-TypeBasedFolderOrder' $hasReorderCall

# ── Test 11: Warning emission logic ─────────────────────────────────────────

Write-Host "`n=== Test 11: Reorder warning emission ===" -ForegroundColor Yellow

$reorderFnSection = [regex]::Match($importContent, 'function Get-TypeBasedFolderOrder[\s\S]*?(?=\nfunction )')
$reorderFnText = $reorderFnSection.Value

$hasWarningText = $reorderFnText -match '\[WARNING\] Import order differs from export folder numbering'
Write-TestResult 'Import: warning message text present' $hasWarningText

$hasReorderedMarker = $reorderFnText -match '<-- reordered'
Write-TestResult 'Import: reordered marker present in warning output' $hasReorderedMarker

# ── Test 12: Fallback handling (no folderOrder in metadata) ─────────────────

Write-Host "`n=== Test 12: Fallback for old exports ===" -ForegroundColor Yellow

$hasFallbackLogic = $reorderFnText -match 'Resolve-FolderTypeFromName'
Write-TestResult 'Import: fallback calls Resolve-FolderTypeFromName' $hasFallbackLogic

$hasFallbackVerbose = $reorderFnText -match 'No folderOrder in metadata'
Write-TestResult 'Import: fallback emits verbose message' $hasFallbackVerbose

# ── Test 13: Canonical order is complete (23 entries, 0-22) ─────────────────

Write-Host "`n=== Test 13: Canonical order completeness ===" -ForegroundColor Yellow

$canonicalMatches = [regex]::Matches($canonicalText, "'(\w+)'\s*=\s*(\d+)")
$ordinals = @{}
foreach ($m in $canonicalMatches) {
  $ordinals[$m.Groups[1].Value] = [int]$m.Groups[2].Value
}
Write-TestResult 'Import: canonical order has 23 entries' ($ordinals.Count -eq 23)

# Check that ordinal values are 0 through 22 (contiguous)
$sortedOrdinals = $ordinals.Values | Sort-Object
$expectedOrdinals = 0..22
$isContiguous = ($sortedOrdinals -join ',') -eq ($expectedOrdinals -join ',')
Write-TestResult 'Import: ordinal values are 0..22 (contiguous)' $isContiguous

# ── Test 14: Simulated reordering with old-style numbering ──────────────────

Write-Host "`n=== Test 14: Simulated reorder (old FK-before-Index numbering) ===" -ForegroundColor Yellow

# Simulate old export numbering where FKs were 10_ and Indexes were 11_
# The canonical order should put indexes before foreign keys

# Re-implement canonical order locally for simulation
$localCanonical = [ordered]@{
  'filegroups'              = 0
  'security'                = 1
  'security_role_members'   = 2
  'database_configuration'  = 3
  'schemas'                 = 4
  'sequences'               = 5
  'partition_functions'     = 6
  'partition_schemes'       = 7
  'types'                   = 8
  'xml_schema_collections'  = 9
  'tables_primarykey'       = 10
  'indexes'                 = 11
  'tables_foreignkeys'      = 12
  'defaults'                = 13
  'rules'                   = 14
  'programmability'         = 15
  'synonyms'                = 16
  'fulltext_search'         = 17
  'external_data'           = 18
  'search_property_lists'   = 19
  'plan_guides'             = 20
  'security_policies'       = 21
  'data'                    = 22
}

# Old-style export folders (wrong order: FK before Indexes)
$oldFolders = @(
  '09_Tables_PrimaryKey',
  '10_Tables_ForeignKeys',  # OLD: FK was 10
  '11_Indexes'              # OLD: Indexes was 11
)

# Build folder-to-type mapping using real Resolve-FolderTypeFromName
$oldTypeMap = @{}
foreach ($f in $oldFolders) {
  $oldTypeMap[$f] = Resolve-FolderTypeFromName -FolderName $f
}

# Sort by canonical order
$reorderedFolders = @($oldFolders | Sort-Object {
    $type = $oldTypeMap[$_]
    if ($localCanonical.Contains($type)) { $localCanonical[$type] } else { 999 }
  })

Write-TestResult 'Simulation: tables_primarykey first after reorder' ($reorderedFolders[0] -eq '09_Tables_PrimaryKey')
Write-TestResult 'Simulation: indexes before FK after reorder' ($reorderedFolders[1] -eq '11_Indexes')
Write-TestResult 'Simulation: FK last after reorder' ($reorderedFolders[2] -eq '10_Tables_ForeignKeys')

# ── Test 15: New export numbering is already correct ────────────────────────

Write-Host "`n=== Test 15: New exports already in correct order ===" -ForegroundColor Yellow

# New-style export folders (correct order)
$newFolders = @(
  '09_Tables_PrimaryKey',
  '10_Indexes',
  '11_Tables_ForeignKeys'
)

$newTypeMap = @{}
foreach ($f in $newFolders) {
  $newTypeMap[$f] = Resolve-FolderTypeFromName -FolderName $f
}

$newReordered = @($newFolders | Sort-Object {
    $type = $newTypeMap[$_]
    if ($localCanonical.Contains($type)) { $localCanonical[$type] } else { 999 }
  })

$noChange = ($newReordered[0] -eq $newFolders[0]) -and ($newReordered[1] -eq $newFolders[1]) -and ($newReordered[2] -eq $newFolders[2])
Write-TestResult 'Simulation: correct-order folders unchanged by reorder' $noChange

# ── Test 16: folderOrder in metadata maps to folder names correctly ─────────

Write-Host "`n=== Test 16: folderOrder metadata folder names ===" -ForegroundColor Yellow

$expectedFolders = @(
  '00_FileGroups', '01_Security', '01_Security_RoleMembers', '02_DatabaseConfiguration', '03_Schemas',
  '04_Sequences', '05_PartitionFunctions', '06_PartitionSchemes', '07_Types',
  '08_XmlSchemaCollections', '09_Tables_PrimaryKey', '10_Indexes',
  '11_Tables_ForeignKeys', '12_Defaults', '13_Rules', '14_Programmability',
  '15_Synonyms', '16_FullTextSearch', '17_ExternalData', '18_SearchPropertyLists',
  '19_PlanGuides', '20_SecurityPolicies', '21_Data'
)

foreach ($folder in $expectedFolders) {
  $hasFolder = $saveMetaText -match [regex]::Escape("'$folder'")
  Write-TestResult "Export: folderOrder includes folder '$folder'" $hasFolder
}

# ── Test 17: Backward compatibility - metadata folderOrder is checked safely ─

Write-Host "`n=== Test 17: Backward compatibility checks ===" -ForegroundColor Yellow

# Verify that Get-TypeBasedFolderOrder handles missing folderOrder
$hasContainsKeyCheck = $reorderFnText -match "ContainsKey\('folderOrder'\)"
Write-TestResult 'Import: checks metadata ContainsKey for folderOrder' $hasContainsKeyCheck

# Verify fallback path exists
$hasFallbackPath = $reorderFnText -match 'No folderOrder in metadata.*fallback'
Write-TestResult 'Import: fallback path for missing folderOrder' $hasFallbackPath

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n=== Summary ===" -ForegroundColor Yellow
Write-Host "  Total: $script:totalTests  Passed: $script:passedTests  Failed: $script:failedTests"

if ($script:failedTests -gt 0) {
  Write-Host "`n  SOME TESTS FAILED" -ForegroundColor Red
  exit 1
}
else {
  Write-Host "`n  ALL TESTS PASSED" -ForegroundColor Green
  exit 0
}
