#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for DatabaseFromEnv and TrustServerCertificateFromEnv parameters
    in Resolve-EnvCredential. These tests do NOT require a SQL Server connection.
#>

$ErrorActionPreference = 'Stop'
$worktreeRoot = Split-Path $PSScriptRoot -Parent

# Load shared functions from Common helper (safe to dot-source — no mandatory params)
$commonScript = Join-Path $worktreeRoot 'Common-SqlServerSchema.ps1'
. $commonScript

$passed = 0
$failed = 0

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Details = '')
    if ($Condition) {
        Write-Host "[PASS] $Name" -ForegroundColor Green
        $script:passed++
    } else {
        Write-Host "[FAIL] $Name$(if ($Details) { ": $Details" })" -ForegroundColor Red
        $script:failed++
    }
}

# ═══════════════════════════════════════════════════════════════
Write-Host "`n=== Unit Tests: DatabaseFromEnv ===`n" -ForegroundColor Cyan
# ═══════════════════════════════════════════════════════════════

# Test 1: DatabaseFromEnv resolves database from env var
$envVar1 = "TEST_DB_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar1, 'MyTestDatabase', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam $envVar1 `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'DatabaseFromEnv resolves database' ($r.Database -eq 'MyTestDatabase') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar1, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 2: CLI -Database takes precedence over DatabaseFromEnv
$envVar2 = "TEST_DB_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar2, 'EnvDatabase', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'CliDatabase' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam $envVar2 `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv'; Database = 'CliDatabase' }
    Assert-True 'CLI -Database takes precedence over DatabaseFromEnv' ($r.Database -eq 'CliDatabase') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar2, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 3: Config connection.databaseFromEnv used as fallback
$envVar3 = "TEST_DB_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar3, 'ConfigEnvDatabase', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithDbEnv = @{ connection = @{ databaseFromEnv = $envVar3 } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config $configWithDbEnv -BoundParameters @{ Server = 'srv' }
    Assert-True 'Config connection.databaseFromEnv resolves database' ($r.Database -eq 'ConfigEnvDatabase') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar3, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 4: DatabaseFromEnv takes precedence over connection string database
$envVar4db = "TEST_DB_$(Get-Random)"
$envVar4cs = "TEST_CS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar4db, 'EnvDb', [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envVar4cs, 'Data Source=srv;Initial Catalog=ConnStrDb;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam $envVar4db `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam $envVar4cs -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'DatabaseFromEnv takes precedence over connection string' ($r.Database -eq 'EnvDb') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar4db, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVar4cs, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 5: Empty/unset env var for DatabaseFromEnv throws error
$envVar5 = "TEST_DB_UNSET_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar5, $null, [System.EnvironmentVariableTarget]::Process)
try {
    Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam $envVar5 `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' } | Out-Null
    Assert-True 'Unset DatabaseFromEnv env var throws' $false 'Expected exception not thrown'
} catch {
    Assert-True 'Unset DatabaseFromEnv env var throws descriptive error' ($_.Exception.Message -match 'not set or is empty') "got '$($_.Exception.Message)'"
}

# Test 6: CLI DatabaseFromEnv takes precedence over config connection.databaseFromEnv
$envVar6cli = "TEST_DB_CLI_$(Get-Random)"
$envVar6cfg = "TEST_DB_CFG_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar6cli, 'CliEnvDb', [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envVar6cfg, 'CfgEnvDb', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithDbEnv = @{ connection = @{ databaseFromEnv = $envVar6cfg } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam $envVar6cli `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config $configWithDbEnv -BoundParameters @{ Server = 'srv' }
    Assert-True 'CLI DatabaseFromEnv takes precedence over config databaseFromEnv' ($r.Database -eq 'CliEnvDb') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar6cli, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVar6cfg, $null, [System.EnvironmentVariableTarget]::Process)
}

# ═══════════════════════════════════════════════════════════════
Write-Host "`n=== Unit Tests: TrustServerCertificateFromEnv ===`n" -ForegroundColor Cyan
# ═══════════════════════════════════════════════════════════════

# Test 7: TrustServerCertificateFromEnv resolves "true"
$envVar7 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar7, 'true', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar7 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv "true" -> $true' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar7, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 8: TrustServerCertificateFromEnv resolves "false"
$envVar8 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar8, 'false', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar8 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv "false" -> $false' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar8, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 9: TrustServerCertificateFromEnv resolves "1"
$envVar9 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar9, '1', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar9 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv "1" -> $true' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar9, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 10: TrustServerCertificateFromEnv resolves "0"
$envVar10 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar10, '0', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar10 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv "0" -> $false' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar10, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 11: CLI -TrustServerCertificate switch takes precedence over TrustServerCertificateFromEnv
$envVar11 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar11, 'true', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar11 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv'; TrustServerCertificate = $false }
    Assert-True 'CLI TrustServerCertificate takes precedence over TrustServerCertificateFromEnv' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar11, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 12: Config connection.trustServerCertificateFromEnv used as fallback
$envVar12 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar12, 'true', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithTrustEnv = @{ connection = @{ trustServerCertificateFromEnv = $envVar12 } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config $configWithTrustEnv -BoundParameters @{ Server = 'srv' }
    Assert-True 'Config connection.trustServerCertificateFromEnv resolves trust' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar12, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 13: TrustServerCertificateFromEnv takes precedence over connection string
$envVar13trust = "TEST_TRUST_$(Get-Random)"
$envVar13cs = "TEST_CS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar13trust, 'false', [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envVar13cs, 'Data Source=srv;Initial Catalog=db;TrustServerCertificate=true', [System.EnvironmentVariableTarget]::Process)
try {
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam $envVar13cs -TrustServerCertificateFromEnvParam $envVar13trust `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv takes precedence over connection string' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar13trust, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVar13cs, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 14: Empty/unset env var for TrustServerCertificateFromEnv throws error
$envVar14 = "TEST_TRUST_UNSET_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar14, $null, [System.EnvironmentVariableTarget]::Process)
try {
    Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar14 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' } | Out-Null
    Assert-True 'Unset TrustServerCertificateFromEnv env var throws' $false 'Expected exception not thrown'
} catch {
    Assert-True 'Unset TrustServerCertificateFromEnv env var throws descriptive error' ($_.Exception.Message -match 'not set or is empty') "got '$($_.Exception.Message)'"
}

# Test 15: Invalid value for TrustServerCertificateFromEnv throws error
$envVar15 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar15, 'yes', [System.EnvironmentVariableTarget]::Process)
try {
    Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar15 `
        -TrustServerCertificateParam $false `
        -Config @{} -BoundParameters @{ Server = 'srv' } | Out-Null
    Assert-True 'Invalid TrustServerCertificateFromEnv value throws' $false 'Expected exception not thrown'
} catch {
    Assert-True 'Invalid TrustServerCertificateFromEnv value throws descriptive error' ($_.Exception.Message -match 'invalid value') "got '$($_.Exception.Message)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar15, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 16: TrustServerCertificateFromEnv takes precedence over config connection.trustServerCertificate (static)
$envVar16 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar16, 'false', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithStaticTrust = @{ connection = @{ trustServerCertificate = $true } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar16 `
        -TrustServerCertificateParam $false `
        -Config $configWithStaticTrust -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv takes precedence over config static trustServerCertificate' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar16, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 17: TrustServerCertificateFromEnv takes precedence over root-level trustServerCertificate
$envVar17 = "TEST_TRUST_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar17, 'false', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithRootTrust = @{ trustServerCertificate = $true }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam '' -TrustServerCertificateFromEnvParam $envVar17 `
        -TrustServerCertificateParam $false `
        -Config $configWithRootTrust -BoundParameters @{ Server = 'srv' }
    Assert-True 'TrustServerCertificateFromEnv takes precedence over root-level trustServerCertificate' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar17, $null, [System.EnvironmentVariableTarget]::Process)
}

# ═══════════════════════════════════════════════════════════════
Write-Host "`n=== Unit Tests: CLI ConnectionStringFromEnv > config *FromEnv precedence ===`n" -ForegroundColor Cyan
# ═══════════════════════════════════════════════════════════════

# Test 18: CLI -ConnectionStringFromEnv takes precedence over config connection.databaseFromEnv
$envVar18db = "TEST_DB_CFG_$(Get-Random)"
$envVar18cs = "TEST_CS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar18db, 'ConfigDb', [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envVar18cs, 'Data Source=srv;Initial Catalog=ConnStrDb;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithDbEnv = @{ connection = @{ databaseFromEnv = $envVar18db } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam '' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam $envVar18cs -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config $configWithDbEnv -BoundParameters @{ Server = 'srv' }
    Assert-True 'CLI ConnectionStringFromEnv takes precedence over config databaseFromEnv' ($r.Database -eq 'ConnStrDb') "got '$($r.Database)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar18db, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVar18cs, $null, [System.EnvironmentVariableTarget]::Process)
}

# Test 19: CLI -ConnectionStringFromEnv takes precedence over config connection.trustServerCertificateFromEnv
$envVar19trust = "TEST_TRUST_CFG_$(Get-Random)"
$envVar19cs = "TEST_CS_$(Get-Random)"
[System.Environment]::SetEnvironmentVariable($envVar19trust, 'false', [System.EnvironmentVariableTarget]::Process)
[System.Environment]::SetEnvironmentVariable($envVar19cs, 'Data Source=srv;Initial Catalog=db;TrustServerCertificate=true', [System.EnvironmentVariableTarget]::Process)
try {
    $configWithTrustEnv = @{ connection = @{ trustServerCertificateFromEnv = $envVar19trust } }
    $r = Resolve-EnvCredential `
        -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
        -ServerFromEnvParam '' -DatabaseFromEnvParam '' `
        -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
        -ConnectionStringFromEnvParam $envVar19cs -TrustServerCertificateFromEnvParam '' `
        -TrustServerCertificateParam $false `
        -Config $configWithTrustEnv -BoundParameters @{ Server = 'srv' }
    Assert-True 'CLI ConnectionStringFromEnv takes precedence over config trustServerCertificateFromEnv' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"
} finally {
    [System.Environment]::SetEnvironmentVariable($envVar19trust, $null, [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVar19cs, $null, [System.EnvironmentVariableTarget]::Process)
}

# Summary
Write-Host "`n=== Summary ===" -ForegroundColor Cyan
Write-Host "Passed: $passed" -ForegroundColor Green
Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
if ($failed -gt 0) { exit 1 } else { exit 0 }
