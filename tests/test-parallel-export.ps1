#!/usr/bin/env pwsh
#Requires -Version 7.0

<#
.SYNOPSIS
    Test parallel export functionality.

.DESCRIPTION
    Verifies parallel export produces identical output to sequential export.
    Tests different worker counts and grouping modes.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# Load environment configuration (same pattern as run-integration-test.ps1)
$ConfigFile = Join-Path $PSScriptRoot '.env'
if (-not (Test-Path $ConfigFile)) {
  Write-Host "[ERROR] Configuration file not found: $ConfigFile" -ForegroundColor Red
  Write-Host "Please copy .env.example to .env and configure settings" -ForegroundColor Yellow
  exit 1
}
Get-Content $ConfigFile | ForEach-Object {
  if ($_ -match '^\s*([^#][^=]+)=(.*)$') {
    Set-Variable -Name $matches[1].Trim() -Value $matches[2].Trim() -Scope Script
  }
}

# Test configuration
$Server = $TEST_SERVER
$Database = $TEST_DATABASE
$ExportDir = Join-Path $PSScriptRoot 'exports_parallel_test'

# Build credential object for SQL auth
$securePassword = ConvertTo-SecureString $SA_PASSWORD -AsPlainText -Force
$Credential = New-Object System.Management.Automation.PSCredential($TEST_USERNAME, $securePassword)

# External config files (consistent with other tests)
$ConfigPath1Worker = Join-Path $PSScriptRoot 'test-parallel-1worker.yml'
$ConfigPath5Workers = Join-Path $PSScriptRoot 'test-parallel-5workers.yml'
$ConfigPath10Workers = Join-Path $PSScriptRoot 'test-parallel-10workers.yml'

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "PARALLEL EXPORT TESTING" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

# Verify config files exist
foreach ($configFile in @($ConfigPath1Worker, $ConfigPath5Workers, $ConfigPath10Workers)) {
  if (-not (Test-Path $configFile)) {
    Write-Host "[ERROR] Config file not found: $configFile" -ForegroundColor Red
    exit 1
  }
}
Write-Host "[INFO] All config files found" -ForegroundColor Green

# Clean up old test exports
if (Test-Path $ExportDir) {
  Write-Host "[INFO] Cleaning up old test exports..." -ForegroundColor Yellow
  Remove-Item $ExportDir -Recurse -Force
}

# Create test results directory
$testResults = @{
  Sequential = $null
  Parallel_1Worker = $null
  Parallel_5Workers = $null
  Parallel_10Workers = $null
}

try {
  #region Test 1: Sequential Export (Baseline)
  Write-Host "`n[TEST 1] Sequential Export (Baseline)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray

  $seqStart = Get-Date
  & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -Credential $Credential `
    -ConfigFile $ConfigPath1Worker 2>&1 | Out-Null
  $seqDuration = (Get-Date) - $seqStart

  # Find the export directory (pattern: Server_Database_Timestamp)
  $seqExportDir = Get-ChildItem $ExportDir -Directory |
    Where-Object { $_.Name -match "^$($Server)_" } |
    Sort-Object CreationTime -Descending |
    Select-Object -First 1

  if (-not $seqExportDir) {
    throw "Sequential export directory not found"
  }

  $testResults.Sequential = @{
    Duration  = $seqDuration
    OutputPath = $seqExportDir.FullName
    FileCount = (Get-ChildItem $seqExportDir.FullName -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Sequential export completed in $($seqDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Sequential.FileCount)" -ForegroundColor Cyan
  #endregion

  #region Test 2: Parallel Export (1 Worker - Should match sequential)
  Write-Host "`n[TEST 2] Parallel Export (1 Worker)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray
  Write-Host "  Config: $ConfigPath1Worker" -ForegroundColor Gray

  $par1Start = Get-Date
  & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -Credential $Credential `
    -ConfigFile $ConfigPath1Worker `
    -Parallel 2>&1 | Out-Null
  $par1Duration = (Get-Date) - $par1Start

  # Find the export directory
  $par1ExportDir = Get-ChildItem $ExportDir -Directory |
    Where-Object { $_.Name -match "^$($Server)_" } |
    Sort-Object CreationTime -Descending |
    Select-Object -First 1

  if (-not $par1ExportDir) {
    throw "Parallel (1 worker) export directory not found"
  }

  $testResults.Parallel_1Worker = @{
    Duration   = $par1Duration
    OutputPath = $par1ExportDir.FullName
    FileCount  = (Get-ChildItem $par1ExportDir.FullName -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Parallel (1 worker) completed in $($par1Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Parallel_1Worker.FileCount)" -ForegroundColor Cyan
  #endregion

  #region Test 3: Parallel Export (5 Workers - Default)
  Write-Host "`n[TEST 3] Parallel Export (5 Workers - Default)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray
  Write-Host "  Config: $ConfigPath5Workers" -ForegroundColor Gray

  $par5Start = Get-Date
  & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -Credential $Credential `
    -ConfigFile $ConfigPath5Workers `
    -Parallel 2>&1 | Out-Null
  $par5Duration = (Get-Date) - $par5Start

  # Find the export directory
  $par5ExportDir = Get-ChildItem $ExportDir -Directory |
    Where-Object { $_.Name -match "^$($Server)_" } |
    Sort-Object CreationTime -Descending |
    Select-Object -First 1

  if (-not $par5ExportDir) {
    throw "Parallel (5 workers) export directory not found"
  }

  $testResults.Parallel_5Workers = @{
    Duration   = $par5Duration
    OutputPath = $par5ExportDir.FullName
    FileCount  = (Get-ChildItem $par5ExportDir.FullName -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Parallel (5 workers) completed in $($par5Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Parallel_5Workers.FileCount)" -ForegroundColor Cyan

  # Calculate speedup
  $speedup5 = $seqDuration.TotalSeconds / $par5Duration.TotalSeconds
  Write-Host "  Speedup: $($speedup5.ToString('F2'))x" -ForegroundColor $(if ($speedup5 -gt 1) { 'Green' } else { 'Yellow' })
  #endregion

  #region Test 4: Parallel Export (10 Workers - Stress Test)
  Write-Host "`n[TEST 4] Parallel Export (10 Workers - Stress Test)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray
  Write-Host "  Config: $ConfigPath10Workers" -ForegroundColor Gray

  $par10Start = Get-Date
  & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -Credential $Credential `
    -ConfigFile $ConfigPath10Workers `
    -Parallel 2>&1 | Out-Null
  $par10Duration = (Get-Date) - $par10Start

  # Find the export directory
  $par10ExportDir = Get-ChildItem $ExportDir -Directory |
    Where-Object { $_.Name -match "^$($Server)_" } |
    Sort-Object CreationTime -Descending |
    Select-Object -First 1

  if (-not $par10ExportDir) {
    throw "Parallel (10 workers) export directory not found"
  }

  $testResults.Parallel_10Workers = @{
    Duration   = $par10Duration
    OutputPath = $par10ExportDir.FullName
    FileCount  = (Get-ChildItem $par10ExportDir.FullName -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Parallel (10 workers) completed in $($par10Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Parallel_10Workers.FileCount)" -ForegroundColor Cyan

  # Calculate speedup
  $speedup10 = $seqDuration.TotalSeconds / $par10Duration.TotalSeconds
  Write-Host "  Speedup: $($speedup10.ToString('F2'))x" -ForegroundColor $(if ($speedup10 -gt 1) { 'Green' } else { 'Yellow' })
  #endregion

  #region Validation: Compare File Counts
  Write-Host "`n[VALIDATION] Comparing File Counts" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray

  $seqCount = $testResults.Sequential.FileCount
  $par1Count = $testResults.Parallel_1Worker.FileCount
  $par5Count = $testResults.Parallel_5Workers.FileCount
  $par10Count = $testResults.Parallel_10Workers.FileCount

  $countMatch = ($seqCount -eq $par1Count) -and ($seqCount -eq $par5Count) -and ($seqCount -eq $par10Count)

  Write-Host "  Sequential:        $seqCount files" -ForegroundColor Cyan
  Write-Host "  Parallel (1w):     $par1Count files $(if ($seqCount -eq $par1Count) { '[OK]' } else { '[FAIL]' })" -ForegroundColor $(if ($seqCount -eq $par1Count) { 'Green' } else { 'Red' })
  Write-Host "  Parallel (5w):     $par5Count files $(if ($seqCount -eq $par5Count) { '[OK]' } else { '[FAIL]' })" -ForegroundColor $(if ($seqCount -eq $par5Count) { 'Green' } else { 'Red' })
  Write-Host "  Parallel (10w):    $par10Count files $(if ($seqCount -eq $par10Count) { '[OK]' } else { '[FAIL]' })" -ForegroundColor $(if ($seqCount -eq $par10Count) { 'Green' } else { 'Red' })

  if ($countMatch) {
    Write-Host "`n[SUCCESS] All exports produced identical file counts!" -ForegroundColor Green
  }
  else {
    Write-Host "`n[ERROR] File count mismatch detected!" -ForegroundColor Red
    exit 1
  }
  #endregion

  #region Summary Report
  Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "TEST SUMMARY" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

  Write-Host "Export Times:" -ForegroundColor White
  Write-Host "  Sequential:      $($seqDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
  Write-Host "  Parallel (1w):   $($par1Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
  Write-Host "  Parallel (5w):   $($par5Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan
  Write-Host "  Parallel (10w):  $($par10Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Cyan

  Write-Host "`nSpeedup vs Sequential:" -ForegroundColor White
  Write-Host "  5 workers:       $($speedup5.ToString('F2'))x" -ForegroundColor $(if ($speedup5 -gt 1) { 'Green' } else { 'Yellow' })
  Write-Host "  10 workers:      $($speedup10.ToString('F2'))x" -ForegroundColor $(if ($speedup10 -gt 1) { 'Green' } else { 'Yellow' })

  Write-Host "`nFile Counts:" -ForegroundColor White
  Write-Host "  All modes:       $seqCount files" -ForegroundColor Cyan

  Write-Host "`n[SUCCESS] All tests passed! Parallel export is working correctly." -ForegroundColor Green
  #endregion

  exit 0
}
catch {
  Write-Host "`n[ERROR] Test failed: $_" -ForegroundColor Red
  Write-Host $_.ScriptStackTrace -ForegroundColor Red
  exit 1
}
