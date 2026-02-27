#Requires -Version 7.0
<#
.SYNOPSIS
    Unit tests for ConvertFrom-AdoConnectionString and Resolve-EnvCredential.
    These tests do NOT require a SQL Server connection.
#>

$ErrorActionPreference = 'Stop'
$worktreeRoot = Split-Path $PSScriptRoot -Parent

# Load the two functions by extracting them from the Export script text, then dot-sourcing a temp file
$scriptContent = Get-Content (Join-Path $worktreeRoot 'Export-SqlServerSchema.ps1') -Raw

# Write a temp file with just the two functions we want to test
$baseTempDir = if ($env:RUNNER_TEMP) { $env:RUNNER_TEMP } else { [System.IO.Path]::GetTempPath() }
$tempFile = Join-Path $baseTempDir "test-connstr-functions-$([System.Guid]::NewGuid().ToString('N')).ps1"
try {
    # Extract function blocks using brace counting
    function Get-FunctionBlock {
        param([string]$Content, [string]$FunctionName)
        $startPattern = "function $FunctionName "
        $startIndex = $Content.IndexOf($startPattern)
        if ($startIndex -lt 0) { throw "Function '$FunctionName' not found" }

        $depth = 0
        $inFunction = $false
        $end = $startIndex
        for ($i = $startIndex; $i -lt $Content.Length; $i++) {
            if ($Content[$i] -eq '{') { $depth++; $inFunction = $true }
            elseif ($Content[$i] -eq '}') {
                $depth--
                if ($inFunction -and $depth -eq 0) { $end = $i; break }
            }
        }
        return $Content.Substring($startIndex, $end - $startIndex + 1)
    }

    $convertFunc = Get-FunctionBlock $scriptContent 'ConvertFrom-AdoConnectionString'
    $resolveFunc = Get-FunctionBlock $scriptContent 'Resolve-EnvCredential'
    "$convertFunc`n`n$resolveFunc" | Set-Content $tempFile -Encoding UTF8

    . $tempFile

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

    Write-Host "`n=== Unit Tests: ConvertFrom-AdoConnectionString ===`n" -ForegroundColor Cyan

    # Test 1: Standard SQL Server keys (Data Source, Initial Catalog, User ID, Password)
    $r = ConvertFrom-AdoConnectionString 'Data Source=myserver,1433;Initial Catalog=mydb;User ID=myuser;Password=mypass;TrustServerCertificate=true'
    Assert-True 'Standard keys - Server' ($r.Server -eq 'myserver,1433') "got '$($r.Server)'"
    Assert-True 'Standard keys - Database' ($r.Database -eq 'mydb') "got '$($r.Database)'"
    Assert-True 'Standard keys - Username' ($r.Username -eq 'myuser') "got '$($r.Username)'"
    Assert-True 'Standard keys - Password' ($r.Password -eq 'mypass') "got '$($r.Password)'"
    Assert-True 'Standard keys - TrustServerCertificate=true' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"

    # Test 2: Alternate aliases recognized by SqlConnectionStringBuilder (Server, Database)
    $r = ConvertFrom-AdoConnectionString 'Server=myserver2;Database=mydb2;User ID=u2;Password=p2'
    Assert-True 'Alias Server -> DataSource' ($r.Server -eq 'myserver2') "got '$($r.Server)'"
    Assert-True 'Alias Database -> InitialCatalog' ($r.Database -eq 'mydb2') "got '$($r.Database)'"
    Assert-True 'User ID' ($r.Username -eq 'u2') "got '$($r.Username)'"
    Assert-True 'Password' ($r.Password -eq 'p2') "got '$($r.Password)'"

    # Test 3: TrustServerCertificate=false
    $r = ConvertFrom-AdoConnectionString 'Data Source=srv;Initial Catalog=db;TrustServerCertificate=false'
    Assert-True 'TrustServerCertificate=false' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"

    # Test 4: TrustServerCertificate not present -> null
    $r = ConvertFrom-AdoConnectionString 'Data Source=srv;Initial Catalog=db;User ID=u;Password=p'
    Assert-True 'TrustServerCertificate absent -> null' ($null -eq $r.TrustServerCertificate) "got '$($r.TrustServerCertificate)'"

    # Test 5: Integrated Security=SSPI (Windows auth)
    $r = ConvertFrom-AdoConnectionString 'Data Source=srv;Initial Catalog=db;Integrated Security=SSPI'
    Assert-True 'Integrated Security=SSPI -> true' ($r.IntegratedSecurity -eq $true) "got '$($r.IntegratedSecurity)'"
    Assert-True 'Integrated Security=SSPI -> no username' ([string]::IsNullOrEmpty($r.Username)) "Username='$($r.Username)'"

    # Test 6: Malformed connection string throws descriptive error
    try {
        ConvertFrom-AdoConnectionString '=bad key=value' | Out-Null
        Assert-True 'Malformed string throws' $false 'Expected exception not thrown'
    } catch {
        Assert-True 'Malformed string throws descriptive error' ($_.Exception.Message -match 'Invalid connection string') "got '$($_.Exception.Message)'"
    }

    # Test 7: Empty/whitespace string returns all nulls (no throw)
    $r = ConvertFrom-AdoConnectionString '   '
    Assert-True 'Whitespace-only string - Server null' ($null -eq $r.Server) "got '$($r.Server)'"
    Assert-True 'Whitespace-only string - Database null' ($null -eq $r.Database) "got '$($r.Database)'"

    # Test 8: Azure SQL connection string
    $r = ConvertFrom-AdoConnectionString 'Server=tcp:myserver.database.windows.net,1433;Initial Catalog=mydb;User ID=admin@myserver;Password=Pass1234!;Encrypt=True;TrustServerCertificate=False;Connection Timeout=30'
    Assert-True 'Azure SQL - Server' ($r.Server -eq 'tcp:myserver.database.windows.net,1433') "got '$($r.Server)'"
    Assert-True 'Azure SQL - Database' ($r.Database -eq 'mydb') "got '$($r.Database)'"
    Assert-True 'Azure SQL - Username' ($r.Username -eq 'admin@myserver') "got '$($r.Username)'"
    Assert-True 'Azure SQL - TrustServerCertificate=False' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"

    Write-Host "`n=== Unit Tests: Resolve-EnvCredential ConnectionString precedence ===`n" -ForegroundColor Cyan

    # Test 9: ConnectionStringFromEnv resolves Server, Database, credentials, and TrustServerCertificate
    $envVarName9 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName9, 'Data Source=testserver;Initial Catalog=testdb;User ID=testuser;Password=testpass;TrustServerCertificate=true', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName9 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{}
        Assert-True 'ConnStr - Server resolved' ($r.Server -eq 'testserver') "got '$($r.Server)'"
        Assert-True 'ConnStr - Database resolved' ($r.Database -eq 'testdb') "got '$($r.Database)'"
        Assert-True 'ConnStr - Credential resolved' ($null -ne $r.Credential) 'Credential was null'
        Assert-True 'ConnStr - Username in credential' ($r.Credential.UserName -eq 'testuser') "got '$($r.Credential.UserName)'"
        Assert-True 'ConnStr - TrustServerCertificate from connstr' ($r.TrustServerCertificate -eq $true) "got '$($r.TrustServerCertificate)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName9, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 10: CLI -Server takes precedence over connection string server
    $envVarName10 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName10, 'Data Source=connstr-server;Initial Catalog=connstr-db;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam 'cli-server' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName10 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{ Server = 'cli-server' }
        Assert-True 'Precedence: CLI Server > ConnStr Server' ($r.Server -eq 'cli-server') "got '$($r.Server)'"
        Assert-True 'Precedence: Database from ConnStr (no CLI -Database)' ($r.Database -eq 'connstr-db') "got '$($r.Database)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName10, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 11: CLI -Database takes precedence over connection string database
    $envVarName11 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName11, 'Data Source=srv;Initial Catalog=connstr-db;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam 'cli-database' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName11 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{ Database = 'cli-database' }
        Assert-True 'Precedence: CLI Database > ConnStr Database' ($r.Database -eq 'cli-database') "got '$($r.Database)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName11, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 12: Individual *FromEnv credentials take precedence over connection string credentials
    $envVarName12cs = "TEST_CONNSTR_$(Get-Random)"
    $envVarName12u  = "TEST_USER_$(Get-Random)"
    $envVarName12p  = "TEST_PASS_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName12cs, 'Data Source=srv;Initial Catalog=db;User ID=wrong-user;Password=wrong-pass', [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVarName12u, 'correct-user', [System.EnvironmentVariableTarget]::Process)
    [System.Environment]::SetEnvironmentVariable($envVarName12p, 'correct-pass', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam $envVarName12u -PasswordFromEnvParam $envVarName12p `
            -ConnectionStringFromEnvParam $envVarName12cs `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{}
        Assert-True 'Precedence: *FromEnv creds > ConnStr creds' ($r.Credential.UserName -eq 'correct-user') "got '$($r.Credential.UserName)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName12cs, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envVarName12u, $null, [System.EnvironmentVariableTarget]::Process)
        [System.Environment]::SetEnvironmentVariable($envVarName12p, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 13: Config connection.connectionStringFromEnv is used as fallback
    $envVarName13 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName13, 'Data Source=config-srv;Initial Catalog=config-db;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
    try {
        $configWithConnStr = @{ connection = @{ connectionStringFromEnv = $envVarName13 } }
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam '' `
            -TrustServerCertificateParam $false `
            -Config $configWithConnStr -BoundParameters @{}
        Assert-True 'Config connectionStringFromEnv - Server' ($r.Server -eq 'config-srv') "got '$($r.Server)'"
        Assert-True 'Config connectionStringFromEnv - Database' ($r.Database -eq 'config-db') "got '$($r.Database)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName13, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 14: Unset env var throws clear error
    $unsetVar14 = "TEST_CONNSTR_UNSET_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($unsetVar14, $null, [System.EnvironmentVariableTarget]::Process)
    try {
        Resolve-EnvCredential `
            -ServerParam 'srv' -DatabaseParam 'db' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $unsetVar14 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{ Server = 'srv' } | Out-Null
        Assert-True 'Unset env var throws' $false 'Expected exception not thrown'
    } catch {
        Assert-True 'Unset env var throws descriptive error' ($_.Exception.Message -match 'not set or is empty') "got '$($_.Exception.Message)'"
    }

    # Test 15: CLI -TrustServerCertificate overrides connection string TrustServerCertificate=true
    $envVarName15 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName15, 'Data Source=srv;Initial Catalog=db;TrustServerCertificate=true', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName15 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{ TrustServerCertificate = $false }
        Assert-True 'Precedence: CLI TrustServerCertificate:$false > ConnStr TrustServerCertificate=true' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName15, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 16: Config trustServerCertificate overrides connection string TrustServerCertificate=true
    $envVarName16 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName16, 'Data Source=srv;Initial Catalog=db;TrustServerCertificate=true', [System.EnvironmentVariableTarget]::Process)
    try {
        $configWithTrust = @{ connection = @{ trustServerCertificate = $false } }
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName16 `
            -TrustServerCertificateParam $false `
            -Config $configWithTrust -BoundParameters @{}
        Assert-True 'Precedence: Config trustServerCertificate:false > ConnStr TrustServerCertificate=true' ($r.TrustServerCertificate -eq $false) "got '$($r.TrustServerCertificate)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName16, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Test 17: Connection string with no Server key -> Server remains null/empty
    $envVarName17 = "TEST_CONNSTR_$(Get-Random)"
    [System.Environment]::SetEnvironmentVariable($envVarName17, 'Initial Catalog=db;User ID=u;Password=p', [System.EnvironmentVariableTarget]::Process)
    try {
        $r = Resolve-EnvCredential `
            -ServerParam '' -DatabaseParam '' -CredentialParam $null `
            -ServerFromEnvParam '' -UsernameFromEnvParam '' -PasswordFromEnvParam '' `
            -ConnectionStringFromEnvParam $envVarName17 `
            -TrustServerCertificateParam $false `
            -Config @{} -BoundParameters @{}
        Assert-True 'ConnStr without Server key -> Server remains null/empty' ([string]::IsNullOrEmpty($r.Server)) "got '$($r.Server)'"
    } finally {
        [System.Environment]::SetEnvironmentVariable($envVarName17, $null, [System.EnvironmentVariableTarget]::Process)
    }

    # Summary
    Write-Host "`n=== Summary ===" -ForegroundColor Cyan
    Write-Host "Passed: $passed" -ForegroundColor Green
    Write-Host "Failed: $failed" -ForegroundColor $(if ($failed -gt 0) { 'Red' } else { 'Green' })
    if ($failed -gt 0) { exit 1 } else { exit 0 }

} finally {
    Remove-Item $tempFile -ErrorAction SilentlyContinue
}
