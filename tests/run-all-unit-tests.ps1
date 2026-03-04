#Requires -Version 7.0

<#
.SYNOPSIS
    Autodiscovery runner for all unit tests (no SQL Server needed).

.DESCRIPTION
    Scans test-*.ps1 files for a '# TestType: unit' header in the first 30 lines
    and runs each match in a child pwsh process. Tracks pass/fail/skip counts and
    prints a summary. Exits 0 on success, 1 on any failure.

.NOTES
    Files with a 'run-' prefix are excluded from autodiscovery.
    Files missing a '# TestType:' header emit a warning but do not fail the run.
#>

param()

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Passed  = 0
$Failed  = 0
$Skipped = 0

# Discover unit test files
$testFiles = Get-ChildItem -Path $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name
$unitTests = @()

foreach ($file in $testFiles) {
    $header = Get-Content $file.FullName -TotalCount 30
    $typeLine = $header | Where-Object { $_ -match '^\s*#\s*TestType:\s*(\S+)' }

    if (-not $typeLine) {
        Write-Host "[WARNING] No TestType header: $($file.Name)" -ForegroundColor Yellow
        $Skipped++
        continue
    }

    $typeLine -match '^\s*#\s*TestType:\s*(\S+)' | Out-Null
    $testType = $Matches[1]

    if ($testType -eq 'unit') {
        $unitTests += $file
    }
}

Write-Host "`n=== Unit Test Autodiscovery ===" -ForegroundColor Cyan
Write-Host "Found $($unitTests.Count) unit test file(s)`n" -ForegroundColor Cyan

foreach ($test in $unitTests) {
    Write-Host "--- Running: $($test.Name) ---" -ForegroundColor Cyan
    $startTime = Get-Date

    & pwsh -NoProfile -File $test.FullName
    $exitCode = $LASTEXITCODE

    $elapsed = (Get-Date) - $startTime
    if ($exitCode -eq 0) {
        Write-Host "[SUCCESS] $($test.Name) ($([math]::Round($elapsed.TotalSeconds, 1))s)`n" -ForegroundColor Green
        $Passed++
    } else {
        Write-Host "[ERROR] $($test.Name) exited with code $exitCode ($([math]::Round($elapsed.TotalSeconds, 1))s)`n" -ForegroundColor Red
        $Failed++
    }
}

# Summary
Write-Host "=== Unit Test Summary ===" -ForegroundColor Cyan
Write-Host "Passed:  $Passed" -ForegroundColor Green
Write-Host "Failed:  $Failed" -ForegroundColor $(if ($Failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Skipped: $Skipped" -ForegroundColor $(if ($Skipped -gt 0) { 'Yellow' } else { 'Green' })

if ($Failed -gt 0) {
    Write-Host "`n[ERROR] $Failed unit test file(s) failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[SUCCESS] All $Passed unit test file(s) passed." -ForegroundColor Green
    exit 0
}
