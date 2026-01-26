<#
.SYNOPSIS
    Tests SMO PrefetchObjects behavior specifically for Synonyms.
.DESCRIPTION
    Minimal test to determine if PrefetchObjects fails for Synonyms.
    
    FINDING: PrefetchObjects(typeof(Synonym)) fails in SMO when called on SQL Server
    running in Linux/Docker containers. This is a confirmed SMO bug/limitation:
    - The typed overload PrefetchObjects(Type) fails ONLY for Synonym
    - The parameterless PrefetchObjects() succeeds for ALL types including Synonyms
    - Direct synonym scripting works fine (lazy loading fallback)
    
    Impact: Negligible - synonyms still export correctly via lazy loading.
    No fix required in Export-SqlServerSchema.ps1 as error is caught and logged.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SYNONYM PREFETCH TEST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

# Import SqlServer module
Import-Module SqlServer -ErrorAction Stop
Write-Host "[OK] SqlServer module loaded" -ForegroundColor Green

# Connect to test database (using SQL auth for Docker container)
$server = "localhost"
$database = "TestDb"
$user = "sa"
$password = "Test@1234"

Write-Host "`nConnecting to $server/$database..." -ForegroundColor Yellow

# Create connection with SQL auth
$connInfo = [Microsoft.SqlServer.Management.Common.SqlConnectionInfo]::new($server)
$connInfo.UserName = $user
$connInfo.Password = $password
$serverConn = [Microsoft.SqlServer.Management.Common.ServerConnection]::new($connInfo)
$smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($serverConn)
$smDatabase = $smServer.Databases[$database]

if ($null -eq $smDatabase) {
    Write-Host "[ERROR] Database '$database' not found" -ForegroundColor Red
    exit 1
}
Write-Host "[OK] Connected to database" -ForegroundColor Green

# Check if synonyms exist
$synonymCount = @($smDatabase.Synonyms | Where-Object { -not $_.IsSystemObject }).Count
Write-Host "`n[INFO] Database has $synonymCount synonym(s)" -ForegroundColor Cyan

# Test PrefetchObjects for each type
Write-Host "`n--- Testing PrefetchObjects for each SMO type ---" -ForegroundColor Yellow

$typesToTest = @(
    @{ Type = [Microsoft.SqlServer.Management.Smo.Table]; Name = 'Table' }
    @{ Type = [Microsoft.SqlServer.Management.Smo.View]; Name = 'View' }
    @{ Type = [Microsoft.SqlServer.Management.Smo.StoredProcedure]; Name = 'StoredProcedure' }
    @{ Type = [Microsoft.SqlServer.Management.Smo.UserDefinedFunction]; Name = 'UserDefinedFunction' }
    @{ Type = [Microsoft.SqlServer.Management.Smo.Schema]; Name = 'Schema' }
    @{ Type = [Microsoft.SqlServer.Management.Smo.Synonym]; Name = 'Synonym' }
)

$results = @()
foreach ($item in $typesToTest) {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $smDatabase.PrefetchObjects($item.Type)
        $timer.Stop()
        $status = "SUCCESS"
        $errMsg = $null
        Write-Host "  [SUCCESS] $($item.Name) - $($timer.ElapsedMilliseconds)ms" -ForegroundColor Green
    }
    catch {
        $timer.Stop()
        $status = "FAILED"
        $errMsg = $_.Exception.Message
        Write-Host "  [FAILED] $($item.Name) - $errMsg" -ForegroundColor Red
    }
    
    $results += [PSCustomObject]@{
        Type = $item.Name
        Status = $status
        DurationMs = $timer.ElapsedMilliseconds
        ErrorMsg = $errMsg
    }
}

# Try alternative: PrefetchObjects with no parameters (all objects)
Write-Host "`n--- Testing PrefetchObjects() with no parameters ---" -ForegroundColor Yellow
try {
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    $smDatabase.PrefetchObjects()
    $timer.Stop()
    Write-Host "  [SUCCESS] PrefetchObjects() (all) - $($timer.ElapsedMilliseconds)ms" -ForegroundColor Green
}
catch {
    Write-Host "  [FAILED] PrefetchObjects() (all) - $($_.Exception.Message)" -ForegroundColor Red
}

# Try scripting a synonym without prefetch to verify synonyms work
Write-Host "`n--- Testing direct Synonym scripting (no prefetch) ---" -ForegroundColor Yellow
$testSynonym = $smDatabase.Synonyms | Where-Object { -not $_.IsSystemObject } | Select-Object -First 1
if ($testSynonym) {
    try {
        $script = $testSynonym.Script()
        Write-Host "  [SUCCESS] Scripted synonym '$($testSynonym.Schema).$($testSynonym.Name)'" -ForegroundColor Green
        Write-Host "  Script preview: $($script[0].Substring(0, [Math]::Min(80, $script[0].Length)))..." -ForegroundColor DarkGray
    }
    catch {
        Write-Host "  [FAILED] Could not script synonym: $($_.Exception.Message)" -ForegroundColor Red
    }
}
else {
    Write-Host "  [SKIP] No synonyms to test" -ForegroundColor Yellow
}

# Summary
Write-Host "`n═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  SUMMARY" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan

$successCount = ($results | Where-Object { $_.Status -eq 'SUCCESS' }).Count
$failCount = ($results | Where-Object { $_.Status -eq 'FAILED' }).Count

Write-Host "  Prefetch Success: $successCount / $($results.Count)" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  Prefetch Failed:  $failCount / $($results.Count)" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

if ($failCount -gt 0) {
    Write-Host "`n  Failed types:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAILED' } | ForEach-Object {
        Write-Host "    - $($_.Type): $($_.ErrorMsg)" -ForegroundColor Red
    }
}

Write-Host ""
