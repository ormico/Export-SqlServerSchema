#Requires -Version 7.0

<#
.SYNOPSIS
    Renders an import-report-*.json file into a human-readable Console summary or Markdown file.

.DESCRIPTION
    Reads a JSON report produced by Import-SqlServerSchema.ps1 and renders it in the requested
    format. The Console format prints a compact summary with colored output. The Markdown format
    writes a .md file with tables for skipped and failed objects.

    The -Diff switch cross-references exportedObjects against importedObjects and skippedObjects
    to flag objects that appear in the export but are missing from both import lists (potential
    silent failures). Diff integrates into whichever format is active.

.PARAMETER ReportPath
    Path to the import-report-*.json file to render. Required.

.PARAMETER Format
    Output format: Console (default) or Markdown.

.PARAMETER Diff
    Cross-reference exportedObjects against importedObjects and skippedObjects to find objects
    that were neither imported nor explicitly skipped (potential silent failures).

.PARAMETER OutputPath
    Override output path for the Markdown file. Defaults to the same directory and base name
    as the JSON report with a .md extension.

.EXAMPLE
    # Print console summary
    ./ConvertTo-ImportReport.ps1 -ReportPath ./import-report-20260225_120000.json

.EXAMPLE
    # Generate Markdown report with diff
    ./ConvertTo-ImportReport.ps1 -ReportPath ./import-report-20260225_120000.json -Format Markdown -Diff

.EXAMPLE
    # Markdown to a custom path
    ./ConvertTo-ImportReport.ps1 -ReportPath ./import-report-20260225_120000.json -Format Markdown -OutputPath ./reports/summary.md

.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema
    Issue: #69 - Import report rendering
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, HelpMessage = 'Path to the import-report-*.json file')]
  [string]$ReportPath,

  [Parameter(HelpMessage = 'Output format: Console (default) or Markdown')]
  [ValidateSet('Console', 'Markdown')]
  [string]$Format = 'Console',

  [Parameter(HelpMessage = 'Cross-reference exportedObjects vs importedObjects+skippedObjects to find missing objects')]
  [switch]$Diff,

  [Parameter(HelpMessage = 'Override output path for Markdown file')]
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# ─────────────────────────────────────────────────────────────────────────────
# Helpers: safe array coercion for StrictMode 3.0 + ConvertFrom-Json
# ConvertFrom-Json returns empty arrays as Object[] with 0 elements (falsy),
# and null properties as $null. @($null) wraps null as a 1-element array.
# These helpers always return a proper [array] with .Count available.
# ─────────────────────────────────────────────────────────────────────────────

function ConvertTo-SafeArray {
  param($Value)
  if ($null -eq $Value) { return , @() }
  return , @($Value)
}

function ConvertTo-MarkdownCell {
  param([string]$Value)
  if (-not $Value) { return '' }
  return $Value -replace '\|', '\|'
}

# ─────────────────────────────────────────────────────────────────────────────
# Functions
# ─────────────────────────────────────────────────────────────────────────────

function Get-ImportReport {
  <#
  .SYNOPSIS
      Loads and validates an import report JSON file.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Report file not found: $Path"
  }

  try {
    [string]$raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $report = $raw | ConvertFrom-Json -Depth 10
  }
  catch {
    throw "Failed to parse report JSON at '$Path': $_"
  }

  # Validate required fields exist on the object
  [array]$propNames = @($report.PSObject.Properties | ForEach-Object { $_.Name })
  $requiredFields = @('exportedObjectCount', 'importedObjectCount', 'skippedObjectCount', 'failedObjectCount')
  foreach ($field in $requiredFields) {
    if ($field -notin $propNames) {
      throw "Report is missing required field: $field"
    }
  }

  return $report
}

function Get-DiffObjects {
  <#
  .SYNOPSIS
      Finds objects in exportedObjects that are missing from importedObjects and skippedObjects.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $Report
  )

  $exportedObjects = ConvertTo-SafeArray $Report.exportedObjects
  if ($exportedObjects.Count -eq 0) {
    Write-Host '[WARNING] Diff requires exportedObjects in the report (needs _export_metadata.json with objects list). No diff available.' -ForegroundColor Yellow
    return , @()
  }

  $seen = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
  $importedObjects = ConvertTo-SafeArray $Report.importedObjects
  $skippedObjects = ConvertTo-SafeArray $Report.skippedObjects
  $failedObjects = ConvertTo-SafeArray $Report.failedObjects

  foreach ($obj in $importedObjects) {
    if ($obj.filePath) { [void]$seen.Add($obj.filePath) }
  }
  foreach ($obj in $skippedObjects) {
    if ($obj.filePath) { [void]$seen.Add($obj.filePath) }
  }
  # Also include failedObjects in the "accounted for" set — they were attempted, not silently missing
  foreach ($obj in $failedObjects) {
    if ($obj.filePath) { [void]$seen.Add($obj.filePath) }
  }

  $missing = [System.Collections.ArrayList]::new()
  foreach ($obj in $exportedObjects) {
    if ($obj.filePath -and -not $seen.Contains($obj.filePath)) {
      [void]$missing.Add($obj)
    }
  }

  return , @($missing)
}

function Get-ReasonKeys {
  <#
  .SYNOPSIS
      Safely extracts reason keys from the skippedReasons object (hashtable or PSCustomObject).
  #>
  [CmdletBinding()]
  param(
    [Parameter()]
    $SkippedReasons
  )

  if (-not $SkippedReasons) { return , @() }

  if ($SkippedReasons -is [System.Collections.IDictionary]) {
    return , @($SkippedReasons.Keys)
  }

  # PSCustomObject from ConvertFrom-Json — enumerate properties safely
  [array]$props = @($SkippedReasons.PSObject.Properties)
  if ($props.Count -eq 0) { return , @() }
  return , @($props | ForEach-Object { $_.Name })
}

function Get-ReasonValue {
  <#
  .SYNOPSIS
      Safely gets a reason count value from skippedReasons by key.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $SkippedReasons,

    [Parameter(Mandatory = $true)]
    [string]$Key
  )

  if ($SkippedReasons -is [System.Collections.IDictionary]) {
    return $SkippedReasons[$Key]
  }
  return $SkippedReasons.$Key
}

function Write-ConsoleReport {
  <#
  .SYNOPSIS
      Renders the import report as a colored console summary.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $Report,

    [Parameter()]
    $MissingObjects
  )

  if ($null -eq $MissingObjects) { $MissingObjects = @() }

  Write-Host ''
  Write-Host '=== Import Report ===' -ForegroundColor Cyan

  # Summary counts
  [int]$exported = $Report.exportedObjectCount
  [int]$imported = $Report.importedObjectCount
  [int]$skipped = $Report.skippedObjectCount
  [int]$failed = $Report.failedObjectCount

  $summaryLine = "  Exported: {0,6}  |  Imported: {1,6}  |  Skipped: {2,6}  |  Failed: {3,6}" -f $exported, $imported, $skipped, $failed
  Write-Host $summaryLine

  # Duration
  if ($Report.duration) {
    Write-Host ("  Duration:  {0}" -f $Report.duration)
  }

  # Skipped reasons breakdown
  $reasonKeys = Get-ReasonKeys -SkippedReasons $Report.skippedReasons
  if ($reasonKeys.Count -gt 0) {
    Write-Host '  Skipped reasons:'
    [int]$maxLen = ($reasonKeys | ForEach-Object { $_.Length } | Measure-Object -Maximum).Maximum
    foreach ($reason in $reasonKeys) {
      $count = Get-ReasonValue -SkippedReasons $Report.skippedReasons -Key $reason
      Write-Host ("    {0,-$maxLen} : {1}" -f $reason, $count) -ForegroundColor Yellow
    }
  }

  # Failed objects
  $failedObjects = ConvertTo-SafeArray $Report.failedObjects
  if ($failedObjects.Count -gt 0) {
    Write-Host '  Failed objects:' -ForegroundColor Red
    foreach ($obj in $failedObjects) {
      $typeDisplay = if ($obj.type) { "[$($obj.type)]" } else { '[Unknown]' }
      $schemaDisplay = if ($obj.schema) { "$($obj.schema)." } else { '' }
      $nameDisplay = if ($obj.name) { $obj.name } else { $obj.filePath }
      Write-Host ("    {0} {1}{2}" -f $typeDisplay, $schemaDisplay, $nameDisplay) -ForegroundColor Red
      if ($obj.errorMessage) {
        # Show first line of error message
        $firstLine = ($obj.errorMessage -split "`n")[0].Trim()
        Write-Host ("      {0}" -f $firstLine) -ForegroundColor Red
      }
    }
  }

  # Missing objects (diff)
  if ($MissingObjects.Count -gt 0) {
    Write-Host ''
    Write-Host ("  Missing objects ({0} not accounted for):" -f $MissingObjects.Count) -ForegroundColor Yellow
    foreach ($obj in $MissingObjects) {
      $typeDisplay = if ($obj.type) { "[$($obj.type)]" } else { '[Unknown]' }
      $schemaDisplay = if ($obj.schema) { "$($obj.schema)." } else { '' }
      $nameDisplay = if ($obj.name) { $obj.name } else { $obj.filePath }
      Write-Host ("    {0} {1}{2}" -f $typeDisplay, $schemaDisplay, $nameDisplay) -ForegroundColor Yellow
    }
  }

  # Report file reference
  Write-Host ("  Report saved: {0}" -f (Split-Path -Path $ReportPath -Leaf))
  Write-Host ''
}

function Export-MarkdownReport {
  <#
  .SYNOPSIS
      Renders the import report as a Markdown file.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)]
    $Report,

    [Parameter()]
    $MissingObjects,

    [Parameter(Mandatory = $true)]
    [string]$ReportJsonPath,

    [Parameter()]
    [string]$DestinationPath
  )

  if ($null -eq $MissingObjects) { $MissingObjects = @() }

  # Resolve output path
  if (-not $DestinationPath) {
    $DestinationPath = [System.IO.Path]::ChangeExtension($ReportJsonPath, '.md')
  }

  $sb = [System.Text.StringBuilder]::new()

  # Header
  [void]$sb.AppendLine('# Import Report')
  [void]$sb.AppendLine('')
  if ($Report.targetServer -or $Report.targetDatabase) {
    [void]$sb.AppendLine("**Target**: ``$($Report.targetServer)`` / ``$($Report.targetDatabase)``")
  }
  if ($Report.sourcePath) {
    [void]$sb.AppendLine("**Source**: ``$($Report.sourcePath)``")
  }
  if ($Report.timestamp) {
    [void]$sb.AppendLine("**Timestamp**: $($Report.timestamp)")
  }
  if ($Report.duration) {
    [void]$sb.AppendLine("**Duration**: $($Report.duration)")
  }
  [void]$sb.AppendLine('')

  # Summary table
  [void]$sb.AppendLine('## Summary')
  [void]$sb.AppendLine('')
  [void]$sb.AppendLine('| Metric | Count |')
  [void]$sb.AppendLine('|--------|-------|')
  [void]$sb.AppendLine("| Exported | $($Report.exportedObjectCount) |")
  [void]$sb.AppendLine("| Imported | $($Report.importedObjectCount) |")
  [void]$sb.AppendLine("| Skipped | $($Report.skippedObjectCount) |")
  [void]$sb.AppendLine("| Failed | $($Report.failedObjectCount) |")
  [void]$sb.AppendLine('')

  # Skipped reasons
  $reasonKeys = Get-ReasonKeys -SkippedReasons $Report.skippedReasons
  if ($reasonKeys.Count -gt 0) {
    [void]$sb.AppendLine('## Skipped Reasons')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Reason | Count |')
    [void]$sb.AppendLine('|--------|-------|')
    foreach ($reason in $reasonKeys) {
      $count = Get-ReasonValue -SkippedReasons $Report.skippedReasons -Key $reason
      $reasonCell = ConvertTo-MarkdownCell $reason
      [void]$sb.AppendLine("| $reasonCell | $count |")
    }
    [void]$sb.AppendLine('')
  }

  # Skipped objects table
  $skippedObjects = ConvertTo-SafeArray $Report.skippedObjects
  if ($skippedObjects.Count -gt 0) {
    [void]$sb.AppendLine('## Skipped Objects')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Type | Schema | Name | Reason |')
    [void]$sb.AppendLine('|------|--------|------|--------|')
    foreach ($obj in $skippedObjects) {
      $type = ConvertTo-MarkdownCell $(if ($obj.type) { $obj.type } else { '' })
      $schema = ConvertTo-MarkdownCell $(if ($obj.schema) { $obj.schema } else { '' })
      $name = ConvertTo-MarkdownCell $(if ($obj.name) { $obj.name } else { '' })
      $reason = ConvertTo-MarkdownCell $(if ($obj.reason) { $obj.reason } else { '' })
      [void]$sb.AppendLine("| $type | $schema | $name | $reason |")
    }
    [void]$sb.AppendLine('')
  }

  # Failed objects table
  $failedObjects = ConvertTo-SafeArray $Report.failedObjects
  if ($failedObjects.Count -gt 0) {
    [void]$sb.AppendLine('## Failed Objects')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Type | Schema | Name | Error |')
    [void]$sb.AppendLine('|------|--------|------|-------|')
    foreach ($obj in $failedObjects) {
      $type = ConvertTo-MarkdownCell $(if ($obj.type) { $obj.type } else { '' })
      $schema = ConvertTo-MarkdownCell $(if ($obj.schema) { $obj.schema } else { '' })
      $name = ConvertTo-MarkdownCell $(if ($obj.name) { $obj.name } else { $obj.filePath })
      $errMsg = if ($obj.errorMessage) {
        $msg = ($obj.errorMessage -split "`n")[0].Trim()
        if ($msg.Length -gt 120) { $msg.Substring(0, 117) + '...' } else { $msg }
      }
      else { '' }
      $errMsg = ConvertTo-MarkdownCell $errMsg
      [void]$sb.AppendLine("| $type | $schema | $name | $errMsg |")
    }
    [void]$sb.AppendLine('')
  }

  # Missing objects table (diff)
  if ($MissingObjects.Count -gt 0) {
    [void]$sb.AppendLine('## Missing Objects (Diff)')
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine("Objects present in the export but not found in imported, skipped, or failed lists ($($MissingObjects.Count) total):")
    [void]$sb.AppendLine('')
    [void]$sb.AppendLine('| Type | Schema | Name | File |')
    [void]$sb.AppendLine('|------|--------|------|------|')
    foreach ($obj in $MissingObjects) {
      $type = ConvertTo-MarkdownCell $(if ($obj.type) { $obj.type } else { '' })
      $schema = ConvertTo-MarkdownCell $(if ($obj.schema) { $obj.schema } else { '' })
      $name = ConvertTo-MarkdownCell $(if ($obj.name) { $obj.name } else { '' })
      $file = ConvertTo-MarkdownCell $(if ($obj.filePath) { $obj.filePath } else { '' })
      [void]$sb.AppendLine("| $type | $schema | $name | $file |")
    }
    [void]$sb.AppendLine('')
  }

  Set-Content -LiteralPath $DestinationPath -Value $sb.ToString() -Encoding UTF8
  Write-Host "[SUCCESS] Markdown report written to: $DestinationPath" -ForegroundColor Green
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────

try {
  $report = Get-ImportReport -Path $ReportPath

  $missingObjects = @()
  if ($Diff) {
    $missingObjects = Get-DiffObjects -Report $report
  }

  if ($Format -eq 'Console') {
    Write-ConsoleReport -Report $report -MissingObjects $missingObjects
  }
  else {
    Export-MarkdownReport -Report $report -MissingObjects $missingObjects -ReportJsonPath $ReportPath -DestinationPath $OutputPath
  }
}
catch {
  Write-Host "[ERROR] Failed to render import report: $_" -ForegroundColor Red
  exit 1
}
