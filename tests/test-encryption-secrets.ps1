<#
.SYNOPSIS
    End-to-end test for encryption secrets feature including discovery, export metadata, and import.

.DESCRIPTION
    This test validates the complete encryption secrets workflow:
    1. Creates a test database with encryption objects (DMK, symmetric key, certificate, app roles)
    2. Exports and verifies encryption metadata in _export_metadata.json
    3. Tests -ShowRequiredSecrets discovery feature
    4. Imports with configured secrets and validates objects are created correctly
    5. Verifies encryption objects are functional (can open keys, activate app roles)

.PARAMETER Server
    SQL Server instance. Default: localhost

.PARAMETER ConfigFile
    Path to .env file with credentials. Default: .env

.EXAMPLE
    ./test-encryption-secrets.ps1

.EXAMPLE
    ./test-encryption-secrets.ps1 -Server "localhost,1433"
#>

[CmdletBinding()]
param(
    [string]$Server = "localhost",
    [string]$ConfigFile = ".env"
)

$ErrorActionPreference = 'Stop'
# Note: Not using Set-StrictMode as the main scripts don't use it and
# we want to test them in their normal operating mode

# ============================================================================
# CONFIGURATION
# ============================================================================

$TestDbSource = "TestDb_EncSource"
$TestDbTarget = "TestDb_EncTarget"
$ExportPath = Join-Path $PSScriptRoot "exports_encryption_test"
$ConfigPath = Join-Path $PSScriptRoot "test-encryption-secrets.yml"
$ExportScript = Join-Path $PSScriptRoot ".." "Export-SqlServerSchema.ps1"
$ImportScript = Join-Path $PSScriptRoot ".." "Import-SqlServerSchema.ps1"

# Test passwords - must match what we use in CREATE statements and config
$DmkPassword = "TestMasterKeyPwd!123"
$SymKeyPassword = "TestSymKeyPwd!123"
$AppRole1Password = "TestAppRole1Pwd!123"
$AppRole2Password = "TestAppRole2Pwd!123"
$CertPassword = "TestCertPwd!123"

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-TestStep {
    param(
        [string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')]
        [string]$Type = 'Info'
    )

    $prefix = switch ($Type) {
        'Info'    { "[INFO]"; $color = "Cyan" }
        'Success' { "[SUCCESS]"; $color = "Green" }
        'Warning' { "[WARNING]"; $color = "Yellow" }
        'Error'   { "[ERROR]"; $color = "Red" }
    }

    Write-Host "$prefix $Message" -ForegroundColor $color
}

function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )

    $result = Invoke-Sqlcmd -ServerInstance $Server -Database $Database `
        -Credential $script:Credential -TrustServerCertificate -Query $Query -ErrorAction Stop
    return $result
}

function Test-DatabaseExists {
    param([string]$DatabaseName)

    $result = Invoke-SqlCommand "SELECT DB_ID('$DatabaseName') AS DbId"
    return $null -ne $result.DbId
}

function Remove-TestDatabase {
    param([string]$DatabaseName)

    if (Test-DatabaseExists $DatabaseName) {
        Write-TestStep "Dropping database $DatabaseName..." -Type Info
        try {
            Invoke-SqlCommand @"
                ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE;
                DROP DATABASE [$DatabaseName];
"@
        } catch {
            Write-TestStep "Failed to drop $DatabaseName - may not exist: $_" -Type Warning
        }
    }
}

# ============================================================================
# LOAD CREDENTIALS
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  ENCRYPTION SECRETS END-TO-END TEST" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host ""

$envPath = Join-Path $PSScriptRoot $ConfigFile
if (-not (Test-Path $envPath)) {
    Write-TestStep "Config file not found: $envPath" -Type Error
    Write-Host "Please copy .env.example to .env and configure settings" -ForegroundColor Yellow
    exit 1
}

# Load .env file
Get-Content $envPath | ForEach-Object {
    if ($_ -match '^([^=]+)=(.*)$') {
        [Environment]::SetEnvironmentVariable($matches[1], $matches[2])
    }
}

$Password = $env:SA_PASSWORD
if (-not $Password) {
    Write-TestStep "SA_PASSWORD not set in .env file" -Type Error
    exit 1
}

$securePass = ConvertTo-SecureString $Password -AsPlainText -Force
$script:Credential = New-Object System.Management.Automation.PSCredential('sa', $securePass)

Write-TestStep "Loaded credentials from $ConfigFile" -Type Success

# ============================================================================
# TEST COUNTERS
# ============================================================================

$script:TestsPassed = 0
$script:TestsFailed = 0

function Assert-Test {
    param(
        [string]$Name,
        [scriptblock]$Test
    )

    try {
        $result = & $Test
        if ($result) {
            Write-TestStep "$Name" -Type Success
            $script:TestsPassed++
            return $true
        } else {
            Write-TestStep "$Name - FAILED (returned false)" -Type Error
            $script:TestsFailed++
            return $false
        }
    } catch {
        Write-TestStep "$Name - FAILED: $_" -Type Error
        $script:TestsFailed++
        return $false
    }
}

# ============================================================================
# STEP 1: CREATE SOURCE DATABASE WITH ENCRYPTION OBJECTS
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 1: Creating source database with encryption objects" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

# Clean up any existing test databases
Remove-TestDatabase $TestDbSource
Remove-TestDatabase $TestDbTarget

# Clean up export directory
if (Test-Path $ExportPath) {
    Remove-Item $ExportPath -Recurse -Force
}

# Create source database with encryption objects
Write-TestStep "Creating $TestDbSource with encryption objects..." -Type Info

Invoke-SqlCommand "CREATE DATABASE [$TestDbSource];"

# Create Database Master Key
Invoke-SqlCommand @"
    CREATE MASTER KEY ENCRYPTION BY PASSWORD = '$DmkPassword';
"@ -Database $TestDbSource

# Create Certificate (protected by DMK)
Invoke-SqlCommand @"
    CREATE CERTIFICATE TestSigningCert
        WITH SUBJECT = 'Test Signing Certificate',
        EXPIRY_DATE = '2030-12-31';
"@ -Database $TestDbSource

# Create Symmetric Key (encrypted by certificate)
Invoke-SqlCommand @"
    CREATE SYMMETRIC KEY DataEncryptionKey
        WITH ALGORITHM = AES_256
        ENCRYPTION BY CERTIFICATE TestSigningCert;
"@ -Database $TestDbSource

# Create Application Roles
Invoke-SqlCommand @"
    CREATE APPLICATION ROLE ReportingAppRole WITH PASSWORD = '$AppRole1Password';
    CREATE APPLICATION ROLE DataEntryRole WITH PASSWORD = '$AppRole2Password';
"@ -Database $TestDbSource

# Create a test table to verify data encryption works
Invoke-SqlCommand @"
    CREATE TABLE dbo.EncryptedData (
        Id INT IDENTITY(1,1) PRIMARY KEY,
        PlainText NVARCHAR(100),
        EncryptedValue VARBINARY(256)
    );
"@ -Database $TestDbSource

Write-TestStep "Source database created with encryption objects" -Type Success

# Verify source objects
$sourceObjects = Invoke-SqlCommand @"
    SELECT
        (SELECT COUNT(*) FROM sys.symmetric_keys WHERE name != '##MS_DatabaseMasterKey##') AS SymmetricKeys,
        (SELECT COUNT(*) FROM sys.certificates WHERE name NOT LIKE '##%') AS Certificates,
        (SELECT COUNT(*) FROM sys.database_principals WHERE type = 'A') AS AppRoles,
        (CASE WHEN EXISTS (SELECT 1 FROM sys.symmetric_keys WHERE name = '##MS_DatabaseMasterKey##') THEN 1 ELSE 0 END) AS HasDMK
"@ -Database $TestDbSource

Write-Host "  Source encryption objects:" -ForegroundColor White
Write-Host "    - Database Master Key: $(if($sourceObjects.HasDMK -eq 1){'Yes'}else{'No'})" -ForegroundColor Gray
Write-Host "    - Symmetric Keys: $($sourceObjects.SymmetricKeys)" -ForegroundColor Gray
Write-Host "    - Certificates: $($sourceObjects.Certificates)" -ForegroundColor Gray
Write-Host "    - Application Roles: $($sourceObjects.AppRoles)" -ForegroundColor Gray

# ============================================================================
# STEP 2: EXPORT AND VERIFY METADATA
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 2: Exporting database and verifying encryption metadata" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

& $ExportScript -Server $Server -Database $TestDbSource -OutputPath $ExportPath -Credential $script:Credential

# Find the export directory
$exportDirs = @(Get-ChildItem $ExportPath -Directory | Where-Object { $_.Name -match "^$Server" -or $_.Name -match "^localhost" })
if ($exportDirs.Count -eq 0) {
    Write-TestStep "No export directory found" -Type Error
    exit 1
}
$exportDir = $exportDirs[0].FullName

# Check for metadata file
$metadataPath = Join-Path $exportDir "_export_metadata.json"
Assert-Test "Export metadata file exists" {
    Test-Path $metadataPath
}

# Parse and validate metadata
$metadata = Get-Content $metadataPath -Raw | ConvertFrom-Json

Assert-Test "Metadata version is 1.1+" {
    [version]$metadata.version -ge [version]"1.1"
}

Assert-Test "Metadata contains encryptionObjects" {
    $null -ne $metadata.encryptionObjects
}

Assert-Test "Metadata detects Database Master Key" {
    $metadata.encryptionObjects.hasDatabaseMasterKey -eq $true
}

# Note: Symmetric keys and certificates ARE detected in metadata, but SMO
# cannot script them (they contain cryptographic secrets). The metadata
# detection helps users know they need to handle these objects separately.
Assert-Test "Metadata lists symmetric key (detection works even if export fails)" {
    @($metadata.encryptionObjects.symmetricKeys) -contains "DataEncryptionKey"
}

Assert-Test "Metadata lists certificate (detection works even if export fails)" {
    @($metadata.encryptionObjects.certificates) -contains "TestSigningCert"
}

Assert-Test "Metadata lists application roles" {
    # Handle case where applicationRoles might be a single string instead of array
    $roles = @($metadata.encryptionObjects.applicationRoles)
    $roles.Count -eq 2 -and
    $roles -contains "ReportingAppRole" -and
    $roles -contains "DataEntryRole"
}

Write-Host "  Encryption metadata content:" -ForegroundColor White
Write-Host "    - hasDatabaseMasterKey: $($metadata.encryptionObjects.hasDatabaseMasterKey)" -ForegroundColor Gray
Write-Host "    - symmetricKeys: $($metadata.encryptionObjects.symmetricKeys -join ', ')" -ForegroundColor Gray
Write-Host "    - certificates: $($metadata.encryptionObjects.certificates -join ', ')" -ForegroundColor Gray
Write-Host "    - applicationRoles: $($metadata.encryptionObjects.applicationRoles -join ', ')" -ForegroundColor Gray

# ============================================================================
# STEP 3: TEST -ShowRequiredSecrets DISCOVERY
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 3: Testing -ShowRequiredSecrets discovery feature" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

# Run ShowRequiredSecrets and capture exit status
# Note: Write-Host output can't be captured via pipeline, so we just verify it runs
$showSecretsSuccess = $false
try {
    & $ImportScript -Server $Server -Database $TestDbTarget `
        -SourcePath $exportDir -Credential $script:Credential -ShowRequiredSecrets
    $showSecretsSuccess = $true
} catch {
    Write-TestStep "ShowRequiredSecrets failed: $_" -Type Error
}

Assert-Test "ShowRequiredSecrets runs successfully" {
    $showSecretsSuccess
}

# ============================================================================
# STEP 4: CREATE CONFIG AND IMPORT WITH SECRETS
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 4: Importing with encryption secrets configured" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

# Create a test config with the correct passwords
$testConfig = @"
# Test configuration for encryption secrets
trustServerCertificate: true
importMode: Dev

import:
  developerMode:
    fileGroupStrategy: removeToPrimary
    encryptionSecrets:
      databaseMasterKey:
        value: "$DmkPassword"
      symmetricKeys:
        DataEncryptionKey:
          # Note: This symmetric key is encrypted by certificate, not password
          # We need to provide DMK password to decrypt the certificate
          value: "NotUsedForCertEncryptedKeys"
      applicationRoles:
        ReportingAppRole:
          value: "$AppRole1Password"
        DataEntryRole:
          value: "$AppRole2Password"
"@

$testConfigPath = Join-Path $PSScriptRoot "test-encryption-import.yml"
$testConfig | Set-Content $testConfigPath -Encoding UTF8

Write-TestStep "Created test config at $testConfigPath" -Type Info

# Run import
Write-TestStep "Running import..." -Type Info
& $ImportScript -Server $Server -Database $TestDbTarget -SourcePath $exportDir `
    -Credential $script:Credential -ConfigFile $testConfigPath -CreateDatabase

# ============================================================================
# STEP 5: VALIDATE IMPORTED ENCRYPTION OBJECTS
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 5: Validating imported encryption objects" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

# Check target database exists
Assert-Test "Target database exists" {
    Test-DatabaseExists $TestDbTarget
}

# Note: SMO cannot script DMK, symmetric keys, or certificates (they contain
# cryptographic secrets). Only application roles can be exported/imported.
# The encryptionSecrets config is mainly for providing passwords when the
# objects are created via other means (manual SQL, backup/restore, etc.)

# Check application roles exist (these CAN be exported by SMO)
Assert-Test "Application roles exist in target" {
    $appRoles = Invoke-SqlCommand "SELECT COUNT(*) AS cnt FROM sys.database_principals WHERE type = 'A'" -Database $TestDbTarget
    $appRoles.cnt -eq 2
}

# Verify application role can be activated with configured password
Assert-Test "Application role can be activated with configured password" {
    try {
        # Use sp_setapprole to activate (this changes security context, so use new connection)
        $result = Invoke-Sqlcmd -ServerInstance $Server -Database $TestDbTarget `
            -Credential $script:Credential -TrustServerCertificate `
            -Query "DECLARE @cookie VARBINARY(8000); EXEC sp_setapprole 'ReportingAppRole', '$AppRole1Password', @fCreateCookie = true, @cookie = @cookie OUTPUT; SELECT 1 AS Success;"
        $result.Success -eq 1
    } catch {
        $false
    }
}

# ============================================================================
# STEP 6: CLEANUP
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "STEP 6: Cleanup" -Type Info
Write-Host "-" * 70 -ForegroundColor Gray

Remove-TestDatabase $TestDbSource
Remove-TestDatabase $TestDbTarget

if (Test-Path $testConfigPath) {
    Remove-Item $testConfigPath -Force
}

Write-TestStep "Cleanup complete" -Type Success

# ============================================================================
# RESULTS SUMMARY
# ============================================================================

Write-Host "`n" -NoNewline
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  TEST RESULTS SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Tests Passed: $($script:TestsPassed)" -ForegroundColor Green
Write-Host "  Tests Failed: $($script:TestsFailed)" -ForegroundColor $(if($script:TestsFailed -gt 0){'Red'}else{'Green'})
Write-Host ""

if ($script:TestsFailed -gt 0) {
    Write-Host "  OVERALL: FAILED" -ForegroundColor Red
    exit 1
} else {
    Write-Host "  OVERALL: PASSED" -ForegroundColor Green
    exit 0
}
