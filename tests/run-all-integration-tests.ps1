#Requires -Version 7.0

<#
.SYNOPSIS
    Autodiscovery runner for all integration tests (requires SQL Server container).

.DESCRIPTION
    Scans test-*.ps1 files for a '# TestType: integration' header in the first 30 lines
    and runs each match in a child pwsh process. Appends run-integration-test.ps1 at the
    end (comprehensive test runs last for fast-feedback ordering).

    For scripts that accept a -ConfigFile parameter, the runner forwards the config file path.

.NOTES
    Files with a 'run-' prefix are excluded from autodiscovery (run-integration-test.ps1
    is explicitly appended instead).
    Files missing a '# TestType:' header emit a warning but do not fail the run.

.PARAMETER ConfigFile
    Path to the .env config file. Defaults to '.env'. Forwarded to scripts that accept it.
#>

param(
    [string]$ConfigFile = '.env'
)

$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot

$Passed  = 0
$Failed  = 0
$Skipped = 0

# Discover integration test files
$testFiles = Get-ChildItem -Path $PSScriptRoot -Filter 'test-*.ps1' | Sort-Object Name
$integrationTests = @()

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

    if ($testType -eq 'integration') {
        $integrationTests += $file
    }
}

# Append run-integration-test.ps1 last (comprehensive test for fast-feedback ordering)
$comprehensiveTest = Join-Path $PSScriptRoot 'run-integration-test.ps1'
if (Test-Path $comprehensiveTest) {
    $integrationTests += Get-Item $comprehensiveTest
}

Write-Host "`n=== Integration Test Autodiscovery ===" -ForegroundColor Cyan
Write-Host "Found $($integrationTests.Count) integration test file(s)`n" -ForegroundColor Cyan

function Test-AcceptsConfigFile {
    param([string]$FilePath)
    $header = Get-Content $FilePath -TotalCount 40
    return ($header | Where-Object { $_ -match '\[string\]\$ConfigFile' }).Count -gt 0
}

foreach ($test in $integrationTests) {
    Write-Host "--- Running: $($test.Name) ---" -ForegroundColor Cyan
    $startTime = Get-Date

    if (Test-AcceptsConfigFile $test.FullName) {
        & pwsh -NoProfile -File $test.FullName -ConfigFile $ConfigFile
    } else {
        & pwsh -NoProfile -File $test.FullName
    }
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
Write-Host "=== Integration Test Summary ===" -ForegroundColor Cyan
Write-Host "Passed:  $Passed" -ForegroundColor Green
Write-Host "Failed:  $Failed" -ForegroundColor $(if ($Failed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Skipped: $Skipped" -ForegroundColor $(if ($Skipped -gt 0) { 'Yellow' } else { 'Green' })

if ($Failed -gt 0) {
    Write-Host "`n[ERROR] $Failed integration test file(s) failed." -ForegroundColor Red
    exit 1
} else {
    Write-Host "`n[SUCCESS] All $Passed integration test file(s) passed." -ForegroundColor Green
    exit 0
}
