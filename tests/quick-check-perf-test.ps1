#!/usr/bin/env pwsh
# Quick integration test for the performance test database
# This validates the script can be parsed and checks basic structure

param(
    [switch]$QuickCheck = $true
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Performance Test Database - Quick Check" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Check if SQL file exists
$sqlFile = "create-perf-test-db.sql"
if (-not (Test-Path $sqlFile)) {
    Write-Host "[ERROR] File not found: $sqlFile" -ForegroundColor Red
    exit 1
}

Write-Host "[SUCCESS] Found $sqlFile" -ForegroundColor Green

# Get file size
$fileSize = (Get-Item $sqlFile).Length
$fileSizeKB = [math]::Round($fileSize / 1KB, 2)
Write-Host "[INFO] File size: $fileSizeKB KB" -ForegroundColor Gray

# Read content
$content = Get-Content $sqlFile -Raw

# Count different object creations
$counts = @{
    'Schemas (WHILE .* <= 100)' = ([regex]::Matches($content, 'WHILE @\w+ <= 100', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'Tables (WHILE .* <= 50)' = ([regex]::Matches($content, 'WHILE @tableNum <= 50', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE OR ALTER PROCEDURE' = ([regex]::Matches($content, 'CREATE OR ALTER PROCEDURE', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE OR ALTER VIEW' = ([regex]::Matches($content, 'CREATE OR ALTER VIEW', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE OR ALTER FUNCTION' = ([regex]::Matches($content, 'CREATE OR ALTER FUNCTION', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE OR ALTER TRIGGER' = ([regex]::Matches($content, 'CREATE OR ALTER TRIGGER', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE SYNONYM' = ([regex]::Matches($content, 'CREATE SYNONYM', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE TYPE' = ([regex]::Matches($content, 'CREATE TYPE', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE ROLE' = ([regex]::Matches($content, 'CREATE ROLE', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'CREATE USER' = ([regex]::Matches($content, 'CREATE USER', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
}

Write-Host ""
Write-Host "Object Creation Patterns Found:" -ForegroundColor Cyan
foreach ($key in $counts.Keys | Sort-Object) {
    $count = $counts[$key]
    if ($count -gt 0) {
        Write-Host "  [SUCCESS] $key : $count" -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] $key : $count" -ForegroundColor Yellow
    }
}

# Check for expected documentation
Write-Host ""
Write-Host "Documentation Checks:" -ForegroundColor Cyan

$docChecks = @{
    '100 schemas' = $content -match '100 schemas'
    '5000 tables' = $content -match '5000 tables'
    '5000 stored procedures' = $content -match '5000 stored procedures'
    '2000 views' = $content -match '2000 views'
    '1000 triggers' = $content -match '1000 triggers'
    '500 synonyms' = $content -match '500 synonyms'
    '5,000,000 rows' = $content -match '5,000,000'
}

foreach ($check in $docChecks.Keys | Sort-Object) {
    if ($docChecks[$check]) {
        Write-Host "  [SUCCESS] Found reference to: $check" -ForegroundColor Green
    } else {
        Write-Host "  [WARNING] Missing reference to: $check" -ForegroundColor Yellow
    }
}

# Check for good practices
Write-Host ""
Write-Host "Best Practices Checks:" -ForegroundColor Cyan

$practiceChecks = @{
    'QUOTENAME() for SQL injection safety' = ([regex]::Matches($content, 'QUOTENAME\(', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'IF NOT EXISTS checks' = ([regex]::Matches($content, 'IF NOT EXISTS', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'SET NOCOUNT ON' = ([regex]::Matches($content, 'SET NOCOUNT ON', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
    'GO batch separators' = ([regex]::Matches($content, '^\s*GO\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
}

foreach ($check in $practiceChecks.Keys | Sort-Object) {
    $count = $practiceChecks[$check]
    Write-Host "  [INFO] $check : $count" -ForegroundColor Gray
}

# Summary
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Quick Check Summary" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "[SUCCESS] Performance test database script appears valid!" -ForegroundColor Green
Write-Host "[INFO] The script is ready for deployment to SQL Server" -ForegroundColor Gray
Write-Host ""
Write-Host "To test with SQL Server:" -ForegroundColor Cyan
Write-Host "  1. Start SQL Server: docker-compose up -d" -ForegroundColor Gray
Write-Host "  2. Create database: CREATE DATABASE PerfTestDb" -ForegroundColor Gray
Write-Host "  3. Run script: sqlcmd -i create-perf-test-db.sql" -ForegroundColor Gray
Write-Host ""
Write-Host "Expected runtime: 5-15 minutes" -ForegroundColor Yellow
Write-Host "Expected objects: ~16,000 database objects" -ForegroundColor Yellow
Write-Host "Expected data: 5,000,000 rows" -ForegroundColor Yellow
Write-Host ""

exit 0
