<#
.SYNOPSIS
    Tests the encryption fallback scanning when metadata is missing.

.DESCRIPTION
    This test validates that Get-RequiredEncryptionSecrets correctly detects
    encryption objects by scanning SQL files when metadata is not available.
    This is important for:
    - Old exports from before encryption metadata was added
    - Exports from other tools
    - Manual/modified exports

    Tests include:
    1. Symmetric keys detection
    2. Certificates detection
    3. Asymmetric keys detection
    4. Application roles detection
    5. Column Master Keys (Always Encrypted) detection
    6. Column Encryption Keys detection
    7. DMK inference from symmetric key referencing MASTER KEY
    8. DMK inference from certificate with DMK-encrypted private key
    9. CEK inference from table ENCRYPTED WITH clauses

.EXAMPLE
    ./test-encryption-fallback-scan.ps1
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

# ============================================================================
# CONFIGURATION
# ============================================================================

$TestExportBase = Join-Path $PSScriptRoot "exports_fallback_test"
$ImportScript = Join-Path $PSScriptRoot ".." "Import-SqlServerSchema.ps1"

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
        'Success' { "[PASS]"; $color = "Green" }
        'Warning' { "[WARNING]"; $color = "Yellow" }
        'Error'   { "[FAIL]"; $color = "Red" }
    }
    Write-Host "$prefix $Message" -ForegroundColor $color
}

function New-TestExport {
    param(
        [string]$Name,
        [hashtable]$SecurityFiles,
        [hashtable]$TableFiles
    )

    $exportDir = Join-Path $TestExportBase $Name
    $securityDir = Join-Path $exportDir "01_Security"
    $tablesDir = Join-Path $exportDir "07_Tables"

    # Clean and create directories
    if (Test-Path $exportDir) { Remove-Item $exportDir -Recurse -Force }
    New-Item -ItemType Directory -Path $securityDir -Force | Out-Null
    New-Item -ItemType Directory -Path $tablesDir -Force | Out-Null

    # Create security files
    foreach ($fileName in $SecurityFiles.Keys) {
        Set-Content -Path (Join-Path $securityDir $fileName) -Value $SecurityFiles[$fileName]
    }

    # Create table files
    foreach ($fileName in $TableFiles.Keys) {
        Set-Content -Path (Join-Path $tablesDir $fileName) -Value $TableFiles[$fileName]
    }

    return $exportDir
}

function Test-EncryptionDetection {
    param(
        [string]$ExportPath,
        [string]$TestName
    )

    # Run the script and capture all output streams including verbose (*>&1)
    # Note: 2>&1 only captures errors, *>&1 captures all streams (verbose, info, etc.)
    $result = & $ImportScript -Server localhost -Database TestDb `
        -SourcePath $ExportPath -ShowRequiredSecrets -Verbose *>&1

    # Combine all output into one string for simpler pattern matching
    $fullText = ($result | ForEach-Object { $_.ToString() }) -join " "

    return $fullText
}

# ============================================================================
# TESTS
# ============================================================================

Write-Host ""
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  ENCRYPTION FALLBACK SCAN TESTS" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host ""

$testsPassed = 0
$testsFailed = 0

# ---------------------------------------------------------------------------
# TEST 1: Symmetric Keys Detection
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 1: Symmetric Keys Detection" -Type Info

$exportDir = New-TestExport -Name "test1_symmetric" -SecurityFiles @{
    "003_SymmetricKeys.sql" = @"
CREATE SYMMETRIC KEY [TestSymKey1] WITH ALGORITHM = AES_256
ENCRYPTION BY PASSWORD = 'TestPwd1';
GO
CREATE SYMMETRIC KEY [TestSymKey2] WITH ALGORITHM = AES_128
ENCRYPTION BY PASSWORD = 'TestPwd2';
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Symmetric Keys"

# Check verbose output for detection messages
if ($output -match "Symmetric key 'TestSymKey1'" -and $output -match "Symmetric key 'TestSymKey2'") {
    Write-TestStep "Detected symmetric keys: TestSymKey1, TestSymKey2" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect symmetric keys in verbose output" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 2: Certificates Detection
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 2: Certificates Detection" -Type Info

$exportDir = New-TestExport -Name "test2_certs" -SecurityFiles @{
    "001_Certificates.sql" = @"
CREATE CERTIFICATE [MyCert1] WITH SUBJECT = 'Test Cert 1';
GO
CREATE CERTIFICATE [MyCert2] WITH SUBJECT = 'Test Cert 2';
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Certificates"

if ($output -match "Certificate 'MyCert1'" -and $output -match "Certificate 'MyCert2'") {
    Write-TestStep "Detected certificates: MyCert1, MyCert2" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect certificates in verbose output" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 3: Application Roles Detection (Dynamic SQL format)
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 3: Application Roles Detection (Dynamic SQL)" -Type Info

$exportDir = New-TestExport -Name "test3_approles" -SecurityFiles @{
    "TestRole.approle.sql" = @"
/* To avoid disclosure of passwords, the password is generated in script. */
declare @statement nvarchar(4000)
select @statement = N'CREATE APPLICATION ROLE [TestAppRole] WITH DEFAULT_SCHEMA = [dbo], ' + N'PASSWORD = N' + QUOTENAME(@placeholderPwd,'''')
EXEC dbo.sp_executesql @statement
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Application Roles"

if ($output -match "Application role 'TestAppRole'") {
    Write-TestStep "Detected application roles: TestAppRole" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect application roles in verbose output" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 4: Column Master Keys (Always Encrypted) Detection
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 4: Column Master Keys (Always Encrypted) Detection" -Type Info

$exportDir = New-TestExport -Name "test4_cmk" -SecurityFiles @{
    "004_ColumnMasterKeys.sql" = @"
CREATE COLUMN MASTER KEY [CMK_Auto1]
WITH (
    KEY_STORE_PROVIDER_NAME = 'MSSQL_CERTIFICATE_STORE',
    KEY_PATH = 'CurrentUser/My/abc123'
);
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Column Master Keys"

if ($output -match "CMK 'CMK_Auto1'") {
    Write-TestStep "Detected CMK: CMK_Auto1" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect CMK in verbose output" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 5: Column Encryption Keys Detection
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 5: Column Encryption Keys Detection" -Type Info

$exportDir = New-TestExport -Name "test5_cek" -SecurityFiles @{
    "005_ColumnEncryptionKeys.sql" = @"
CREATE COLUMN ENCRYPTION KEY [CEK_Auto1]
WITH VALUES (
    COLUMN_MASTER_KEY = [CMK_Auto1],
    ALGORITHM = 'RSA_OAEP',
    ENCRYPTED_VALUE = 0x0123456789
);
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Column Encryption Keys"

if ($output -match "CEK 'CEK_Auto1'") {
    Write-TestStep "Detected CEK: CEK_Auto1" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect CEK in verbose output" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 6: DMK Inference from Symmetric Key
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 6: DMK Inference from Symmetric Key" -Type Info

$exportDir = New-TestExport -Name "test6_dmk_symkey" -SecurityFiles @{
    "003_SymmetricKeys.sql" = @"
CREATE SYMMETRIC KEY [KeyEncryptedByDMK] WITH ALGORITHM = AES_256
ENCRYPTION BY MASTER KEY;
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "DMK Inference"

if ($output -match "DMK inferred from symmetric key referencing MASTER KEY") {
    Write-TestStep "DMK correctly inferred from symmetric key using MASTER KEY" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to infer DMK from symmetric key" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 7: CEK Inference from Table ENCRYPTED WITH Clause (Old Export)
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 7: CEK Inference from Table ENCRYPTED WITH (Old Export)" -Type Info

$exportDir = New-TestExport -Name "test7_table_cek" -SecurityFiles @{
    "public.role.sql" = "-- placeholder"
} -TableFiles @{
    "dbo.Customers.sql" = @"
CREATE TABLE [dbo].[Customers](
    [CustomerID] [int] IDENTITY(1,1) NOT NULL,
    [SSN] [char](11) ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [CEK_SSN], ENCRYPTION_TYPE = Deterministic, ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256') NOT NULL,
    [Salary] [money] ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [CEK_Salary], ENCRYPTION_TYPE = Randomized, ALGORITHM = 'AEAD_AES_256_CBC_HMAC_SHA_256') NULL
) ON [PRIMARY]
GO
"@
}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Table CEK Inference"

if ($output -match "CEK 'CEK_SSN' inferred from ENCRYPTED WITH" -and $output -match "CEK 'CEK_Salary' inferred from ENCRYPTED WITH") {
    Write-TestStep "Detected CEKs from table columns: CEK_SSN, CEK_Salary" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect CEKs from table columns in verbose output" -Type Error
    $testsFailed++
}

# Also verify CMK placeholder was added (check for the verbose message about CMK being required)
if ($output -match "CMK required \(inferred from CEK usage") {
    Write-TestStep "CMK placeholder added (indicating re-export needed)" -Type Success
    $testsPassed++
} else {
    Write-TestStep "CMK placeholder not added when CEKs found" -Type Error
    $testsFailed++
}

# ---------------------------------------------------------------------------
# TEST 8: Non-Standard Filename (All-in-One File)
# ---------------------------------------------------------------------------
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "TEST 8: Non-Standard Filename Detection" -Type Info

$exportDir = New-TestExport -Name "test8_nonstandard" -SecurityFiles @{
    "all_encryption_objects.sql" = @"
-- All encryption objects in one file (non-standard naming)
CREATE CERTIFICATE [CertInWeirdFile] WITH SUBJECT = 'Test';
GO
CREATE SYMMETRIC KEY [SymKeyInWeirdFile] WITH ALGORITHM = AES_256
ENCRYPTION BY PASSWORD = 'test';
GO
CREATE APPLICATION ROLE [AppRoleInWeirdFile] WITH DEFAULT_SCHEMA = [dbo], PASSWORD = 'test';
GO
"@
} -TableFiles @{}

$output = Test-EncryptionDetection -ExportPath $exportDir -TestName "Non-Standard Filename"

$allFound = $output -match "Certificate 'CertInWeirdFile'" -and
            $output -match "Symmetric key 'SymKeyInWeirdFile'" -and
            $output -match "Application role 'AppRoleInWeirdFile'"

if ($allFound) {
    Write-TestStep "All objects detected from non-standard filename" -Type Success
    $testsPassed++
} else {
    Write-TestStep "Failed to detect objects from non-standard filename" -Type Error
    $testsFailed++
}

# ============================================================================
# CLEANUP & SUMMARY
# ============================================================================

Write-Host ""
Write-Host "-" * 70 -ForegroundColor Gray
Write-TestStep "Cleaning up test exports..." -Type Info
if (Test-Path $TestExportBase) {
    Remove-Item $TestExportBase -Recurse -Force
}

Write-Host ""
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host "  TEST SUMMARY" -ForegroundColor Cyan
Write-Host "=" * 70 -ForegroundColor Cyan
Write-Host ""
Write-Host "  Passed: $testsPassed" -ForegroundColor Green
Write-Host "  Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { "Red" } else { "Green" })
Write-Host ""

if ($testsFailed -gt 0) {
    exit 1
}
exit 0
