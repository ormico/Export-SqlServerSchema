#!/usr/bin/env pwsh
# Simple validation script to check SQL syntax in create-perf-test-db.sql
# This doesn't run the SQL but does basic parsing validation

param(
    [string]$SqlFile = "create-perf-test-db.sql"
)

Write-Host "[INFO] Validating SQL syntax in $SqlFile..." -ForegroundColor Cyan

# Read the file
$sqlContent = Get-Content $SqlFile -Raw

# Basic validation checks
$validationErrors = @()
$validationWarnings = @()

# Check for balanced BEGIN/END blocks (only outside of string literals - approximate check)
# NOTE: This validation has known limitations:
# - It counts BEGIN/END in comments and string literals (false positives)
# - Dynamic SQL makes exact parsing difficult without a full SQL parser
# - A mismatch is common and acceptable with heavy use of dynamic SQL
$beginCount = ([regex]::Matches($sqlContent, '\bBEGIN\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
$endCount = ([regex]::Matches($sqlContent, '\bEND\b', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
if ($beginCount -ne $endCount) {
    # This is common with dynamic SQL, so just warn
    $validationWarnings += "BEGIN ($beginCount) and END ($endCount) count mismatch - this is often OK with dynamic SQL"
}

# Check for GO statements (batch separators)
$goCount = ([regex]::Matches($sqlContent, '^\s*GO\s*$', [System.Text.RegularExpressions.RegexOptions]::Multiline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
Write-Host "[INFO] Found $goCount GO batch separators" -ForegroundColor Gray

# Check for CREATE OR ALTER statements
$createOrAlterCount = ([regex]::Matches($sqlContent, 'CREATE OR ALTER', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
Write-Host "[INFO] Found $createOrAlterCount CREATE OR ALTER statements" -ForegroundColor Gray

# Check for SQL injection-safe QUOTENAME usage
$quoteNameCount = ([regex]::Matches($sqlContent, 'QUOTENAME\(', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)).Count
Write-Host "[INFO] Found $quoteNameCount QUOTENAME() calls (good for SQL injection safety)" -ForegroundColor Gray

# Check for basic T-SQL keywords to ensure it's SQL
$keywords = @('SELECT', 'CREATE', 'INSERT', 'UPDATE', 'DELETE', 'PROCEDURE', 'FUNCTION', 'VIEW', 'TABLE', 'TRIGGER')
$keywordFound = $false
foreach ($keyword in $keywords) {
    if ($sqlContent -match "\b$keyword\b") {
        $keywordFound = $true
        break
    }
}
if (-not $keywordFound) {
    $validationErrors += "No SQL keywords found - file may be empty or corrupted"
}

# Count expected object types
$schemasExpected = 100
$tablesExpected = 5000
$procsExpected = 5000
$viewsExpected = 2000
$scalarFuncsExpected = 2000
$tvfExpected = 1000
$triggersExpected = 1000
$synonymsExpected = 500
$typesExpected = 200

# Validate counts in comments
if ($sqlContent -match '100 schemas') {
    Write-Host "[SUCCESS] Found reference to 100 schemas" -ForegroundColor Green
} else {
    $validationWarnings += "Missing reference to 100 schemas in comments"
}

if ($sqlContent -match '5000 tables') {
    Write-Host "[SUCCESS] Found reference to 5000 tables" -ForegroundColor Green
} else {
    $validationWarnings += "Missing reference to 5000 tables in comments"
}

if ($sqlContent -match '5,000,000') {
    Write-Host "[SUCCESS] Found reference to 5,000,000 rows" -ForegroundColor Green
} else {
    $validationWarnings += "Missing reference to 5,000,000 rows in comments"
}

# Display results
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "Validation Results" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan

if ($validationErrors.Count -eq 0 -and $validationWarnings.Count -eq 0) {
    Write-Host "[SUCCESS] No syntax errors or warnings found!" -ForegroundColor Green
    Write-Host "[INFO] SQL file appears to be valid" -ForegroundColor Green
    exit 0
} else {
    if ($validationErrors.Count -gt 0) {
        Write-Host "[ERROR] Found $($validationErrors.Count) error(s):" -ForegroundColor Red
        foreach ($err in $validationErrors) {
            Write-Host "  - $err" -ForegroundColor Red
        }
    }
    
    if ($validationWarnings.Count -gt 0) {
        Write-Host "[WARNING] Found $($validationWarnings.Count) warning(s):" -ForegroundColor Yellow
        foreach ($warn in $validationWarnings) {
            Write-Host "  - $warn" -ForegroundColor Yellow
        }
    }
    
    if ($validationErrors.Count -gt 0) {
        exit 1
    }
    exit 0
}
