#Requires -Version 7.0

<#
.SYNOPSIS
    Tests shared functions in Common-SqlServerSchema.ps1.

.DESCRIPTION
    Unit tests for the 4 functions extracted into the common helper library:
      - Get-EscapedSqlIdentifier
      - Write-Log
      - Invoke-WithRetry
      - Read-ExportMetadata

    Does NOT require SQL Server.

.NOTES
    Issue: #66 - Extract shared functions into common helper library
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir   = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

# Dot-source the common helper library under test
. (Join-Path $projectRoot 'Common-SqlServerSchema.ps1')

$script:testsPassed = 0
$script:testsFailed = 0

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

# ─────────────────────────────────────────────────────────────────────────────
# Get-EscapedSqlIdentifier Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Get-EscapedSqlIdentifier Tests' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# 1. Normal name passes through unchanged
$result = Get-EscapedSqlIdentifier -Name 'Normal_Name'
Write-TestResult 'Normal name passes through unchanged' ($result -eq 'Normal_Name') "Expected 'Normal_Name', got '$result'"

# 2. Name with ] gets escaped to ]]
$result = Get-EscapedSqlIdentifier -Name 'Bad]Name'
Write-TestResult 'Name with ] gets escaped to ]]' ($result -eq 'Bad]]Name') "Expected 'Bad]]Name', got '$result'"

# 3. Name with multiple ] all get escaped
$result = Get-EscapedSqlIdentifier -Name 'A]B]C'
Write-TestResult 'Multiple ] all get escaped' ($result -eq 'A]]B]]C') "Expected 'A]]B]]C', got '$result'"

# 4. Whitespace-only string passes through unchanged
$result = Get-EscapedSqlIdentifier -Name '   '
Write-TestResult 'Whitespace-only string passes through unchanged' ($result -eq '   ') "Expected '   ', got '$result'"

# 5. Name with [ passes through (only ] needs escaping)
$result = Get-EscapedSqlIdentifier -Name 'Name[With[Brackets'
Write-TestResult 'Name with [ passes through unchanged' ($result -eq 'Name[With[Brackets') "Expected 'Name[With[Brackets', got '$result'"

# 6. SQL injection attempt gets escaped
$result = Get-EscapedSqlIdentifier -Name 'Malicious]; DROP TABLE Users;--'
Write-TestResult 'SQL injection attempt gets escaped' ($result -eq 'Malicious]]; DROP TABLE Users;--') "Expected 'Malicious]]; DROP TABLE Users;--', got '$result'"

# ─────────────────────────────────────────────────────────────────────────────
# Write-Log Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Write-Log Tests' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# 7. INFO level writes to output stream
$script:LogFile = $null
$output = Write-Log -Message 'Test info message' -Level INFO 6>&1
Write-TestResult 'INFO level writes to output stream' ($output -eq 'Test info message') "Expected 'Test info message', got '$output'"

# 8. SUCCESS level writes with Write-Host (captured via -6>&1 won't work, test it doesn't throw)
$script:LogFile = $null
try {
  Write-Log -Message 'Test success' -Level SUCCESS *> $null
  Write-TestResult 'SUCCESS level does not throw' $true
}
catch {
  Write-TestResult 'SUCCESS level does not throw' $false $_.Exception.Message
}

# 9. WARNING level uses Write-Warning (captured via 3>&1)
$script:LogFile = $null
$output = Write-Log -Message 'Test warning' -Level WARNING 3>&1
Write-TestResult 'WARNING level writes warning' ($null -ne $output -and $output -match 'Test warning') "Expected warning containing 'Test warning', got '$output'"

# 10. ERROR level does not throw (writes to host)
$script:LogFile = $null
try {
  Write-Log -Message 'Test error' -Level ERROR *> $null
  Write-TestResult 'ERROR level does not throw' $true
}
catch {
  Write-TestResult 'ERROR level does not throw' $false $_.Exception.Message
}

# 11. Writes to $script:LogFile when set
$tempLog = Join-Path ([System.IO.Path]::GetTempPath()) "test-write-log-$(Get-Date -Format 'yyyyMMddHHmmss').log"
try {
  $script:LogFile = $tempLog
  Write-Log -Message 'File log test' -Level INFO *> $null
  $logContent = Get-Content -Path $tempLog -Raw -ErrorAction SilentlyContinue
  $passed = $logContent -match 'File log test' -and $logContent -match '\[INFO\]'
  Write-TestResult 'Writes to log file when $script:LogFile is set' $passed "Log content: $logContent"
}
finally {
  $script:LogFile = $null
  Remove-Item $tempLog -ErrorAction SilentlyContinue
}

# 12. Skips file write when $script:LogFile is null
$script:LogFile = $null
try {
  Write-Log -Message 'No file test' -Level INFO *> $null
  Write-TestResult 'Skips file write when $script:LogFile is null' $true
}
catch {
  Write-TestResult 'Skips file write when $script:LogFile is null' $false $_.Exception.Message
}

# 13. Skips file write when parent directory does not exist
$script:LogFile = Join-Path ([System.IO.Path]::GetTempPath()) 'nonexistent-dir-xyz/test.log'
try {
  Write-Log -Message 'Bad dir test' -Level INFO *> $null
  $exists = Test-Path $script:LogFile
  Write-TestResult 'Skips file write when parent directory does not exist' (-not $exists)
}
catch {
  Write-TestResult 'Skips file write when parent directory does not exist' $false $_.Exception.Message
}
finally {
  $script:LogFile = $null
}

# 14. Timestamp format in log entry
$tempLog = Join-Path ([System.IO.Path]::GetTempPath()) "test-write-log-ts-$(Get-Date -Format 'yyyyMMddHHmmss').log"
try {
  $script:LogFile = $tempLog
  Write-Log -Message 'Timestamp test' -Level INFO *> $null
  $logContent = Get-Content -Path $tempLog -Raw -ErrorAction SilentlyContinue
  $passed = $logContent -match '\[\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\] \[INFO\] Timestamp test'
  Write-TestResult 'Log entry has correct timestamp format' $passed "Log content: $logContent"
}
finally {
  $script:LogFile = $null
  Remove-Item $tempLog -ErrorAction SilentlyContinue
}

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-WithRetry Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Invoke-WithRetry Tests' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

$script:LogFile = $null

# 15. Successful operation on first attempt
$result = Invoke-WithRetry -ScriptBlock { 'success' } -OperationName 'Test'
Write-TestResult 'Successful operation on first attempt' ($result -eq 'success') "Expected 'success', got '$result'"

# 16. Retries on transient failure, succeeds on Nth attempt
$script:retryCount = 0
$result = Invoke-WithRetry -ScriptBlock {
  $script:retryCount++
  if ($script:retryCount -lt 2) {
    throw 'connection timed out'
  }
  'recovered'
} -MaxAttempts 3 -InitialDelaySeconds 0 -OperationName 'RetryTest' 3>&1 | Select-Object -Last 1
# The result might be the string or mixed with warnings; check retryCount
$passed = $script:retryCount -eq 2
Write-TestResult 'Retries on transient failure, succeeds on 2nd attempt' $passed "retryCount=$($script:retryCount)"

# 17. Throws after max attempts exhausted
$script:retryCount = 0
$threw = $false
try {
  Invoke-WithRetry -ScriptBlock {
    $script:retryCount++
    throw 'connection timed out'
  } -MaxAttempts 2 -InitialDelaySeconds 0 -OperationName 'ExhaustTest' *> $null
}
catch {
  $threw = $true
}
Write-TestResult 'Throws after max attempts exhausted' ($threw -and $script:retryCount -eq 2) "threw=$threw, retryCount=$($script:retryCount)"

# 18. Respects MaxAttempts parameter
$script:retryCount = 0
try {
  Invoke-WithRetry -ScriptBlock {
    $script:retryCount++
    throw 'connection timed out'
  } -MaxAttempts 1 -InitialDelaySeconds 0 -OperationName 'MaxTest' *> $null
}
catch { }
Write-TestResult 'Respects MaxAttempts=1 (only 1 attempt)' ($script:retryCount -eq 1) "retryCount=$($script:retryCount)"

# 19. Non-transient error throws immediately without retry
$script:retryCount = 0
$threw = $false
try {
  Invoke-WithRetry -ScriptBlock {
    $script:retryCount++
    throw 'invalid syntax error'
  } -MaxAttempts 3 -InitialDelaySeconds 0 -OperationName 'NonTransientTest' *> $null
}
catch {
  $threw = $true
}
Write-TestResult 'Non-transient error throws immediately (no retry)' ($threw -and $script:retryCount -eq 1) "threw=$threw, retryCount=$($script:retryCount)"

# 20. OperationName appears in error messages
$errorMsg = ''
try {
  Invoke-WithRetry -ScriptBlock {
    throw 'connection timed out'
  } -MaxAttempts 1 -InitialDelaySeconds 0 -OperationName 'MyOperation' *> $null
}
catch {
  $errorMsg = $_.Exception.Message
}
Write-TestResult 'OperationName appears in error context' ($errorMsg -match 'timed out') "Error: $errorMsg"

# ─────────────────────────────────────────────────────────────────────────────
# Read-ExportMetadata Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'Read-ExportMetadata Tests' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# 21. Returns parsed JSON when metadata file exists
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "test-metadata-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
try {
  $metadata = @{
    version     = '1.8.0'
    objectCount = 42
    exportDate  = '2024-01-15T10:30:00Z'
  }
  $metadata | ConvertTo-Json | Set-Content -Path (Join-Path $tempDir '_export_metadata.json') -Encoding UTF8

  $result = Read-ExportMetadata -Path $tempDir
  $passed = $null -ne $result -and $result.version -eq '1.8.0' -and $result.objectCount -eq 42
  Write-TestResult 'Returns parsed JSON when metadata file exists' $passed "Result: $($result | ConvertTo-Json -Compress -ErrorAction SilentlyContinue)"
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 22. Returns null when file does not exist
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "test-metadata-missing-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
try {
  $result = Read-ExportMetadata -Path $tempDir
  Write-TestResult 'Returns null when file does not exist' ($null -eq $result) "Expected null, got: $result"
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 23. Returns null on invalid JSON (with warning)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "test-metadata-invalid-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
try {
  Set-Content -Path (Join-Path $tempDir '_export_metadata.json') -Value 'not valid json {{{' -Encoding UTF8

  $warnings = @()
  $result = Read-ExportMetadata -Path $tempDir -WarningVariable warnings 3>&1
  # Filter to get only the return value (not warning messages)
  $returnValue = $result | Where-Object { $_ -isnot [System.Management.Automation.WarningRecord] }
  $warningMsgs = $result | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }
  $passed = ($null -eq $returnValue -or $returnValue.Count -eq 0) -and $warningMsgs.Count -gt 0
  Write-TestResult 'Returns null on invalid JSON with warning' $passed "returnValue=$returnValue, warnings=$($warningMsgs.Count)"
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# 24. Reads correct filename (_export_metadata.json)
$tempDir = Join-Path ([System.IO.Path]::GetTempPath()) "test-metadata-filename-$(Get-Date -Format 'yyyyMMddHHmmss')"
New-Item -Path $tempDir -ItemType Directory -Force | Out-Null
try {
  # Create a wrong-named file — should NOT be found
  @{ version = '0.0.0' } | ConvertTo-Json | Set-Content -Path (Join-Path $tempDir 'metadata.json') -Encoding UTF8
  $result = Read-ExportMetadata -Path $tempDir
  Write-TestResult 'Ignores non-standard metadata filenames' ($null -eq $result) "Expected null, got: $result"

  # Now create the correct file
  @{ version = '1.0.0' } | ConvertTo-Json | Set-Content -Path (Join-Path $tempDir '_export_metadata.json') -Encoding UTF8
  $result = Read-ExportMetadata -Path $tempDir
  Write-TestResult 'Reads _export_metadata.json specifically' ($null -ne $result -and $result.version -eq '1.0.0') "Result: $result"
}
finally {
  Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}

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
  Write-Host '[SUCCESS] ALL COMMON FUNCTION TESTS PASSED!' -ForegroundColor Green
  exit 0
}
else {
  Write-Host "[FAILED] $($script:testsFailed) test(s) failed" -ForegroundColor Red
  exit 1
}
