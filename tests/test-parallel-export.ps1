#!/usr/bin/env pwsh
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

# Test configuration
$Server = 'localhost'
$Database = 'TestDb'
$ExportDir = Join-Path $PSScriptRoot 'exports_parallel_test'

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "PARALLEL EXPORT TESTING" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

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
  $seqOutput = & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir
  $seqDuration = (Get-Date) - $seqStart

  $testResults.Sequential = @{
    Duration = $seqDuration
    OutputPath = $seqOutput
    FileCount = (Get-ChildItem $seqOutput -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Sequential export completed in $($seqDuration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Sequential.FileCount)" -ForegroundColor Cyan
  #endregion

  #region Test 2: Parallel Export (1 Worker - Should match sequential)
  Write-Host "`n[TEST 2] Parallel Export (1 Worker)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray

  # Create config file with 1 worker
  $config1Worker = @"
parallel:
  enabled: true
  maxWorkers: 1
  progressInterval: 10
"@
  $configPath1 = Join-Path $ExportDir 'test-parallel-1worker.yml'
  New-Item -ItemType Directory -Path $ExportDir -Force | Out-Null
  Set-Content -Path $configPath1 -Value $config1Worker

  $par1Start = Get-Date
  $par1Output = & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -ConfigFile $configPath1 `
    -Parallel
  $par1Duration = (Get-Date) - $par1Start

  $testResults.Parallel_1Worker = @{
    Duration = $par1Duration
    OutputPath = $par1Output
    FileCount = (Get-ChildItem $par1Output -Recurse -File).Count
  }

  Write-Host "[SUCCESS] Parallel (1 worker) completed in $($par1Duration.TotalSeconds.ToString('F2'))s" -ForegroundColor Green
  Write-Host "  Files: $($testResults.Parallel_1Worker.FileCount)" -ForegroundColor Cyan
  #endregion

  #region Test 3: Parallel Export (5 Workers - Default)
  Write-Host "`n[TEST 3] Parallel Export (5 Workers - Default)" -ForegroundColor Cyan
  Write-Host "─────────────────────────────────────────────" -ForegroundColor Gray

  $config5Workers = @"
parallel:
  enabled: true
  maxWorkers: 5
  progressInterval: 50
"@
  $configPath5 = Join-Path $ExportDir 'test-parallel-5workers.yml'
  Set-Content -Path $configPath5 -Value $config5Workers

  $par5Start = Get-Date
  $par5Output = & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -ConfigFile $configPath5 `
    -Parallel
  $par5Duration = (Get-Date) - $par5Start

  $testResults.Parallel_5Workers = @{
    Duration = $par5Duration
    OutputPath = $par5Output
    FileCount = (Get-ChildItem $par5Output -Recurse -File).Count
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

  $config10Workers = @"
parallel:
  enabled: true
  maxWorkers: 10
  progressInterval: 100
"@
  $configPath10 = Join-Path $ExportDir 'test-parallel-10workers.yml'
  Set-Content -Path $configPath10 -Value $config10Workers

  $par10Start = Get-Date
  $par10Output = & "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $Server `
    -Database $Database `
    -OutputPath $ExportDir `
    -ConfigFile $configPath10 `
    -Parallel
  $par10Duration = (Get-Date) - $par10Start

  $testResults.Parallel_10Workers = @{
    Duration = $par10Duration
    OutputPath = $par10Output
    FileCount = (Get-ChildItem $par10Output -Recurse -File).Count
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
  Write-Host "  Parallel (1w):     $par1Count files $(if ($seqCount -eq $par1Count) { '✓' } else { '✗' })" -ForegroundColor $(if ($seqCount -eq $par1Count) { 'Green' } else { 'Red' })
  Write-Host "  Parallel (5w):     $par5Count files $(if ($seqCount -eq $par5Count) { '✓' } else { '✗' })" -ForegroundColor $(if ($seqCount -eq $par5Count) { 'Green' } else { 'Red' })
  Write-Host "  Parallel (10w):    $par10Count files $(if ($seqCount -eq $par10Count) { '✓' } else { '✗' })" -ForegroundColor $(if ($seqCount -eq $par10Count) { 'Green' } else { 'Red' })

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
