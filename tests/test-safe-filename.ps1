#Requires -Version 7.0

<#
.SYNOPSIS
    Tests Get-SafeFileName handles SQL Server object names that are
    problematic as filenames on Windows and Linux.

.DESCRIPTION
    SQL Server bracketed identifiers can contain characters that are
    illegal or problematic in filenames: spaces, dots, reserved Windows
    names, special characters, leading/trailing whitespace, and more.

    This test verifies that Get-SafeFileName sanitizes all these cases
    to produce valid, safe filenames on both platforms.

.NOTES
    Issue: Verify filenames derived from SQL object names are safe on
    Windows and Linux filesystems.
#>
# TestType: unit

param()

$ErrorActionPreference = 'Stop'
$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$script:testsPassed = 0
$script:testsFailed = 0

# ─────────────────────────────────────────────────────────────────────────────
# Extract Get-SafeFileName from Export-SqlServerSchema.ps1
# ─────────────────────────────────────────────────────────────────────────────

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$exportContent = Get-Content $exportScript -Raw

function Get-FunctionBlock {
  param([string]$Content, [string]$FunctionName)
  $startPattern = "function $FunctionName "
  $startIndex = $Content.IndexOf($startPattern)
  if ($startIndex -lt 0) { throw "Function '$FunctionName' not found in export script" }
  $depth = 0; $inFunction = $false; $end = $startIndex
  for ($i = $startIndex; $i -lt $Content.Length; $i++) {
    if ($Content[$i] -eq '{') { $depth++; $inFunction = $true }
    elseif ($Content[$i] -eq '}') {
      $depth--
      if ($inFunction -and $depth -eq 0) { $end = $i; break }
    }
  }
  if ((-not $inFunction) -or ($end -le $startIndex)) {
    throw "Function '$FunctionName' could not be fully extracted because no matching closing brace was found"
  }
  return $Content.Substring($startIndex, $end - $startIndex + 1)
}

$functionBlock = Get-FunctionBlock -Content $exportContent -FunctionName 'Get-SafeFileName'
$tempFunctionPath = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ("Get-SafeFileName_{0}.ps1" -f [System.Guid]::NewGuid().ToString('N'))
try {
  Set-Content -Path $tempFunctionPath -Value $functionBlock -Encoding UTF8
  . $tempFunctionPath
}
finally {
  Remove-Item -Path $tempFunctionPath -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Helper
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

function Test-SafeFileName {
  param(
    [string]$TestName,
    [string]$InputName,
    [string]$Expected
  )
  $result = Get-SafeFileName -Name $InputName
  Write-TestResult $TestName ($result -eq $Expected) "Input='$InputName' Expected='$Expected' Got='$result'"
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Spaces in object names
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: Spaces in Names' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'Simple space in view name' 'My View' 'My View'
Test-SafeFileName 'Multiple spaces in name' 'Order Detail Summary' 'Order Detail Summary'
Test-SafeFileName 'Leading space is trimmed' ' LeadingSpace' 'LeadingSpace'
Test-SafeFileName 'Trailing space is trimmed' 'TrailingSpace ' 'TrailingSpace'
Test-SafeFileName 'Leading and trailing spaces trimmed' ' Padded Name ' 'Padded Name'

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Dots / periods in object names
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: Dots in Names' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'Dot in middle of name' 'sys.audit' 'sys.audit'
Test-SafeFileName 'Multiple dots in name' 'a.b.c.d' 'a.b.c.d'
Test-SafeFileName 'Leading dot is trimmed' '.hidden' 'hidden'
Test-SafeFileName 'Trailing dot is trimmed' 'trailing.' 'trailing'
Test-SafeFileName 'Leading and trailing dots trimmed' '..dotted..' 'dotted'

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Windows reserved filenames
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: Windows Reserved Names' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'CON is prefixed with underscore' 'CON' '_CON'
Test-SafeFileName 'PRN is prefixed with underscore' 'PRN' '_PRN'
Test-SafeFileName 'AUX is prefixed with underscore' 'AUX' '_AUX'
Test-SafeFileName 'NUL is prefixed with underscore' 'NUL' '_NUL'
Test-SafeFileName 'COM1 is prefixed with underscore' 'COM1' '_COM1'
Test-SafeFileName 'LPT1 is prefixed with underscore' 'LPT1' '_LPT1'
Test-SafeFileName 'CON with extension is prefixed' 'CON.old' '_CON.old'
Test-SafeFileName 'Normal name starting with CON is unchanged' 'CONTROL' 'CONTROL'
Test-SafeFileName 'Normal name starting with NUL is unchanged' 'NULLABLE' 'NULLABLE'

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Characters invalid in filenames
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: Invalid Filename Characters' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'Colon replaced with underscore' 'time:stamp' 'time_stamp'
Test-SafeFileName 'Backslash replaced' 'path\name' 'path_name'
Test-SafeFileName 'Forward slash replaced' 'path/name' 'path_name'
Test-SafeFileName 'Angle brackets replaced' '<output>' '_output_'
Test-SafeFileName 'Double quote replaced' 'say"hello"' 'say_hello_'
Test-SafeFileName 'Pipe replaced' 'A|B' 'A_B'
Test-SafeFileName 'Question mark replaced' 'what?' 'what_'
Test-SafeFileName 'Asterisk replaced' 'star*name' 'star_name'
Test-SafeFileName 'Multiple invalid chars replaced' 'a<b>c:d' 'a_b_c_d'

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Special characters legal in SQL but worth verifying in filenames
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: SQL-Legal Special Characters' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'Hash sign preserved' 'temp#table' 'temp#table'
Test-SafeFileName 'Dollar sign preserved' 'price$calc' 'price$calc'
Test-SafeFileName 'At sign preserved' '@variable' '@variable'
Test-SafeFileName 'Ampersand preserved' 'A&B' 'A&B'
Test-SafeFileName 'Exclamation preserved' 'alert!' 'alert!'
Test-SafeFileName 'Percent preserved' '100%done' '100%done'
Test-SafeFileName 'Caret preserved' 'x^2' 'x^2'
Test-SafeFileName 'Plus sign preserved' 'A+B' 'A+B'
Test-SafeFileName 'Equals sign preserved' 'key=value' 'key=value'
Test-SafeFileName 'Tilde preserved' '~temp' '~temp'
Test-SafeFileName 'Backtick preserved' 'back`tick' 'back`tick'
Test-SafeFileName 'Parentheses preserved' 'func(1)' 'func(1)'
Test-SafeFileName 'Square brackets preserved' 'arr[0]' 'arr[0]'
Test-SafeFileName 'Curly braces preserved' '{guid}' '{guid}'
Test-SafeFileName 'Semicolon preserved' 'a;b' 'a;b'
Test-SafeFileName 'Single quote preserved' "it's" "it's"
Test-SafeFileName 'Comma preserved' 'a,b' 'a,b'

# ─────────────────────────────────────────────────────────────────────────────
# Tests: Edge cases
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-SafeFileName Tests: Edge Cases' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

Test-SafeFileName 'Empty string returns unnamed' '' 'unnamed'
Test-SafeFileName 'Whitespace-only returns unnamed' '   ' 'unnamed'
Test-SafeFileName 'Dots-only returns unnamed' '...' 'unnamed'
Test-SafeFileName 'Normal name passes through' 'Customers' 'Customers'
Test-SafeFileName 'Underscores preserved' 'my_table_name' 'my_table_name'
Test-SafeFileName 'Hyphens preserved' 'my-view-name' 'my-view-name'

# Long name truncation
$longName = 'A' * 250
$result = Get-SafeFileName -Name $longName
Write-TestResult 'Long name truncated to 200 chars' ($result.Length -eq 200) "Length=$($result.Length)"

# Realistic SQL object names with spaces
Test-SafeFileName 'Realistic view with spaces' 'Customer Order Summary' 'Customer Order Summary'
Test-SafeFileName 'Realistic proc with spaces' 'Get Customer Orders' 'Get Customer Orders'
Test-SafeFileName 'Mixed spaces and special chars' 'My View (v2)' 'My View (v2)'
Test-SafeFileName 'Space with dot' 'audit.log backup' 'audit.log backup'

# Combined edge cases
Test-SafeFileName 'Reserved name with space' 'CON figuration' 'CON figuration'
Test-SafeFileName 'All invalid chars become underscores' '<>:"/\|?*' '_________'

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'TEST SUMMARY' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

$total = $script:testsPassed + $script:testsFailed
Write-Host "Tests Passed: $($script:testsPassed) / $total" -ForegroundColor $(if ($script:testsFailed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ''

if ($script:testsFailed -eq 0) {
  Write-Host '[SUCCESS] ALL SAFE FILENAME TESTS PASSED!' -ForegroundColor Green
  exit 0
}
else {
  Write-Host "[FAILED] $($script:testsFailed) test(s) failed" -ForegroundColor Red
  exit 1
}
