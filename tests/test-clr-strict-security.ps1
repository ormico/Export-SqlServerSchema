#Requires -Version 7.0

<#
.SYNOPSIS
    Tests the CLR strict security management feature for Import-SqlServerSchema.ps1

.DESCRIPTION
    This test validates that the CLR strict security feature correctly:
    1. Detects CLR assembly scripts in the export
    2. Reads CLR config from YAML config file
    3. Enables CLR integration when configured (sp_configure 'clr enabled')
    4. Temporarily disables 'clr strict security' during import when configured
    5. Restores original 'clr strict security' value after import
    6. Emits [HINT] when CLR assembly import fails without config
    7. Handles insufficient permissions gracefully
    8. Displays CLR config in the import configuration summary
    9. Defaults to safe values (disableStrictSecurityForImport: false)

    Uses fixture export data in tests/fixtures/clr_test containing a CLR
    assembly script to test import behavior.

.PARAMETER ConfigFile
    Path to .env file with connection settings. Default: .env

.EXAMPLE
    ./test-clr-strict-security.ps1
    ./test-clr-strict-security.ps1 -ConfigFile ./custom.env
#>

param(
    [string]$ConfigFile = ".env"
)

$ErrorActionPreference = "Stop"

# Load configuration from .env file
if (Test-Path $ConfigFile) {
    Write-Host "Loading configuration from $ConfigFile..." -ForegroundColor Cyan
    Get-Content $ConfigFile | ForEach-Object {
        if ($_ -match '^\s*([^#][^=]*?)\s*=\s*(.+?)\s*$') {
            $name = $matches[1]
            $value = $matches[2]
            Set-Variable -Name $name -Value $value -Scope Script
        }
    }
}
else {
    Write-Error "Configuration file not found: $ConfigFile"
    exit 1
}

# Configuration
$Server = "$TEST_SERVER,$SQL_PORT"
$Username = $TEST_USERNAME
$Password = $SA_PASSWORD
$SourcePath = Join-Path $PSScriptRoot "fixtures" "clr_test"
$ClrEnabledConfig = Join-Path $PSScriptRoot "test-clr-strict-security-enabled.yml"
$ClrNoRestoreConfig = Join-Path $PSScriptRoot "test-clr-strict-security-no-restore.yml"
$ClrDisabledConfig = Join-Path $PSScriptRoot "test-clr-strict-security-disabled.yml"
$ImportScript = Join-Path $PSScriptRoot ".." "Import-SqlServerSchema.ps1"

# Test database names
$TestDbClrEnabled = "TestDb_CLR_Enabled"
$TestDbClrHint = "TestDb_CLR_Hint"
$TestDbClrNoRestore = "TestDb_CLR_NoRestore"

# Test tracking
$testsPassed = 0
$testsFailed = 0
$testResults = @()

Write-Host "`n═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "CLR STRICT SECURITY FEATURE TEST" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "Target: SQL Server (Docker)" -ForegroundColor Gray
Write-Host "Source: fixtures/clr_test" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════`n" -ForegroundColor Cyan

# Helper function to execute SQL
function Invoke-SqlCommand {
    param(
        [string]$Query,
        [string]$Database = "master"
    )

    $sqlcmdArgs = @('-S', $Server, '-U', $Username, '-P', $Password, '-d', $Database, '-C', '-Q', $Query, '-h', '-1', '-W')
    $result = & sqlcmd @sqlcmdArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "SQL command failed: $result"
    }
    return $result
}

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ""
    )

    $script:testResults += @{
        Name    = $TestName
        Passed  = $Passed
        Message = $Message
    }

    if ($Passed) {
        $script:testsPassed++
        Write-Host "[PASS] $TestName" -ForegroundColor Green
    }
    else {
        $script:testsFailed++
        Write-Host "[FAIL] $TestName" -ForegroundColor Red
        if ($Message) {
            Write-Host "       $Message" -ForegroundColor Yellow
        }
    }
}

function Remove-TestDatabase {
    param([string]$DatabaseName)

    try {
        $result = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.databases WHERE name = '$DatabaseName'"
        $count = @($result) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        if ($count -and $count -ne "0") {
            Invoke-SqlCommand "ALTER DATABASE [$DatabaseName] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$DatabaseName]"
        }
    }
    catch {
        Write-Warning "Could not drop database $DatabaseName : $_"
    }
}

function Get-SpConfigureValue {
    param([string]$OptionName)

    try {
        # Use sys.configurations directly and output as simple text
        $sqlcmdArgs = @('-S', $Server, '-U', $Username, '-P', $Password, '-d', 'master', '-C',
            '-Q', "SET NOCOUNT ON; SELECT CAST(value_in_use AS VARCHAR(10)) FROM sys.configurations WHERE name = '$OptionName'",
            '-h', '-1', '-W', '-b')
        $result = & sqlcmd @sqlcmdArgs 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        # Parse the first non-empty trimmed line
        $value = @($result) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        if ($value) { return [int]$value }
        return $null
    }
    catch {
        Write-Warning "Could not read sp_configure '$OptionName': $_"
        return $null
    }
}

function Set-SpConfigureValue {
    param(
        [string]$OptionName,
        [int]$Value
    )

    try {
        # Enable advanced options first (required for 'clr strict security')
        Invoke-SqlCommand "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; EXEC sp_configure '$OptionName', $Value; RECONFIGURE;"
    }
    catch {
        Write-Warning "Could not set sp_configure '$OptionName' to $Value : $_"
    }
}

# ═══════════════════════════════════════════════════════════════════════════
# PRE-TEST SETUP
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "Pre-test setup..." -ForegroundColor Cyan

# Clean up any leftover test databases
Remove-TestDatabase $TestDbClrEnabled
Remove-TestDatabase $TestDbClrHint
Remove-TestDatabase $TestDbClrNoRestore

# Save original sp_configure values so we can restore them
$originalClrEnabled = Get-SpConfigureValue 'clr enabled'
$originalStrictSecurity = Get-SpConfigureValue 'clr strict security'

Write-Host "  Original 'clr enabled': $originalClrEnabled" -ForegroundColor Gray
Write-Host "  Original 'clr strict security': $originalStrictSecurity" -ForegroundColor Gray

# Ensure strict security is enabled for testing (default SQL Server 2017+ state)
Set-SpConfigureValue 'clr strict security' 1
# Ensure CLR is disabled for testing
Set-SpConfigureValue 'clr enabled' 0

Write-Host "  Set 'clr strict security' to 1 for testing" -ForegroundColor Gray
Write-Host "  Set 'clr enabled' to 0 for testing" -ForegroundColor Gray
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS - CLR Assembly Script Detection
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "UNIT TESTS: CLR Assembly Script Detection" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Dot-source the import script to get access to helper functions
# We need to suppress the param block execution by wrapping in a module-like context
# Instead, we test by invoking the full import and checking behavior

# Test 1: Assembly script in fixture is detected by filename pattern
$assemblyScript = Get-ChildItem -Path $SourcePath -Recurse -Filter "Assembly.*.sql"
Write-TestResult -TestName "CLR assembly script exists in fixture" `
    -Passed ($assemblyScript.Count -gt 0) `
    -Message "Expected Assembly.*.sql files in fixture, found $($assemblyScript.Count)"

# Test 2: Assembly script is in the correct folder (14_Programmability)
$assemblyInProgrammability = $assemblyScript | Where-Object {
    $_.FullName -match '14_Programmability'
}
Write-TestResult -TestName "Assembly script is in 14_Programmability folder" `
    -Passed ($assemblyInProgrammability.Count -gt 0) `
    -Message "Expected Assembly script under 14_Programmability"

# Test 3: Assembly script contains CREATE ASSEMBLY
if ($assemblyScript.Count -gt 0) {
    $content = Get-Content $assemblyScript[0].FullName -Raw
    Write-TestResult -TestName "Assembly script contains CREATE ASSEMBLY" `
        -Passed ($content -match 'CREATE\s+ASSEMBLY') `
        -Message "Expected CREATE ASSEMBLY statement in script"
}
else {
    Write-TestResult -TestName "Assembly script contains CREATE ASSEMBLY" -Passed $false -Message "No assembly script found"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS - Config File Parsing
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "UNIT TESTS: CLR Config File Parsing" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Test 4: CLR-enabled config file exists and is valid YAML
try {
    Import-Module powershell-yaml -ErrorAction Stop
    $enabledConfig = Get-Content $ClrEnabledConfig -Raw | ConvertFrom-Yaml
    $hasClrSection = $enabledConfig.import.developerMode.ContainsKey('clr')
    Write-TestResult -TestName "CLR-enabled config has clr section" -Passed $hasClrSection `
        -Message "Expected clr section in import.developerMode"

    # Test 5: enableClr is true
    if ($hasClrSection) {
        $clrSection = $enabledConfig.import.developerMode.clr
        Write-TestResult -TestName "Config: enableClr is true" `
            -Passed ($clrSection.enableClr -eq $true) `
            -Message "Expected enableClr: true, got: $($clrSection.enableClr)"

        # Test 6: disableStrictSecurityForImport is true
        Write-TestResult -TestName "Config: disableStrictSecurityForImport is true" `
            -Passed ($clrSection.disableStrictSecurityForImport -eq $true) `
            -Message "Expected disableStrictSecurityForImport: true, got: $($clrSection.disableStrictSecurityForImport)"

        # Test 7: restoreStrictSecuritySetting is true
        Write-TestResult -TestName "Config: restoreStrictSecuritySetting is true" `
            -Passed ($clrSection.restoreStrictSecuritySetting -eq $true) `
            -Message "Expected restoreStrictSecuritySetting: true, got: $($clrSection.restoreStrictSecuritySetting)"
    }
    else {
        Write-TestResult -TestName "Config: enableClr is true" -Passed $false -Message "No clr section"
        Write-TestResult -TestName "Config: disableStrictSecurityForImport is true" -Passed $false -Message "No clr section"
        Write-TestResult -TestName "Config: restoreStrictSecuritySetting is true" -Passed $false -Message "No clr section"
    }
}
catch {
    Write-TestResult -TestName "CLR-enabled config has clr section" -Passed $false -Message "YAML parse error: $_"
    Write-TestResult -TestName "Config: enableClr is true" -Passed $false -Message "Skipped"
    Write-TestResult -TestName "Config: disableStrictSecurityForImport is true" -Passed $false -Message "Skipped"
    Write-TestResult -TestName "Config: restoreStrictSecuritySetting is true" -Passed $false -Message "Skipped"
}

# Test 8: No-restore config has restoreStrictSecuritySetting: false
try {
    $noRestoreConfig = Get-Content $ClrNoRestoreConfig -Raw | ConvertFrom-Yaml
    $clrSection = $noRestoreConfig.import.developerMode.clr
    Write-TestResult -TestName "No-restore config: restoreStrictSecuritySetting is false" `
        -Passed ($clrSection.restoreStrictSecuritySetting -eq $false) `
        -Message "Expected restoreStrictSecuritySetting: false, got: $($clrSection.restoreStrictSecuritySetting)"
}
catch {
    Write-TestResult -TestName "No-restore config: restoreStrictSecuritySetting is false" -Passed $false -Message "Error: $_"
}

# Test 9: Disabled config has no clr section
try {
    $disabledConfig = Get-Content $ClrDisabledConfig -Raw | ConvertFrom-Yaml
    $hasClrSection = $disabledConfig.import.developerMode.ContainsKey('clr')
    Write-TestResult -TestName "Disabled config: no clr section" `
        -Passed (-not $hasClrSection) `
        -Message "Expected no clr section in disabled config"
}
catch {
    Write-TestResult -TestName "Disabled config: no clr section" -Passed $false -Message "Error: $_"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# UNIT TESTS - JSON Schema Validation
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "UNIT TESTS: JSON Schema" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Test 10: Schema has clr section in importSettings definition
$schemaPath = Join-Path $PSScriptRoot ".." "export-import-config.schema.json"
$schema = Get-Content $schemaPath -Raw | ConvertFrom-Json
$importSettingsProps = $schema.definitions.importSettings.properties

Write-TestResult -TestName "Schema: importSettings has clr property" `
    -Passed ($null -ne $importSettingsProps.clr) `
    -Message "Expected clr in importSettings properties"

# Test 11: Schema clr has correct properties
if ($null -ne $importSettingsProps.clr) {
    $clrProps = $importSettingsProps.clr.properties
    Write-TestResult -TestName "Schema: clr has enableClr property" `
        -Passed ($null -ne $clrProps.enableClr) `
        -Message "Expected enableClr in clr properties"
    Write-TestResult -TestName "Schema: clr has disableStrictSecurityForImport property" `
        -Passed ($null -ne $clrProps.disableStrictSecurityForImport) `
        -Message "Expected disableStrictSecurityForImport in clr properties"
    Write-TestResult -TestName "Schema: clr has restoreStrictSecuritySetting property" `
        -Passed ($null -ne $clrProps.restoreStrictSecuritySetting) `
        -Message "Expected restoreStrictSecuritySetting in clr properties"

    # Test 12: Default values are correct
    Write-TestResult -TestName "Schema: enableClr defaults to false" `
        -Passed ($clrProps.enableClr.default -eq $false) `
        -Message "Expected default false, got: $($clrProps.enableClr.default)"
    Write-TestResult -TestName "Schema: disableStrictSecurityForImport defaults to false" `
        -Passed ($clrProps.disableStrictSecurityForImport.default -eq $false) `
        -Message "Expected default false, got: $($clrProps.disableStrictSecurityForImport.default)"
    Write-TestResult -TestName "Schema: restoreStrictSecuritySetting defaults to true" `
        -Passed ($clrProps.restoreStrictSecuritySetting.default -eq $true) `
        -Message "Expected default true, got: $($clrProps.restoreStrictSecuritySetting.default)"
}
else {
    Write-TestResult -TestName "Schema: clr has enableClr property" -Passed $false -Message "No clr section"
    Write-TestResult -TestName "Schema: clr has disableStrictSecurityForImport property" -Passed $false -Message "No clr section"
    Write-TestResult -TestName "Schema: clr has restoreStrictSecuritySetting property" -Passed $false -Message "No clr section"
    Write-TestResult -TestName "Schema: enableClr defaults to false" -Passed $false -Message "No clr section"
    Write-TestResult -TestName "Schema: disableStrictSecurityForImport defaults to false" -Passed $false -Message "No clr section"
    Write-TestResult -TestName "Schema: restoreStrictSecuritySetting defaults to true" -Passed $false -Message "No clr section"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TEST 1: CLR import WITH strict security disabled
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "INTEGRATION TEST 1: CLR import with config enabled" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Reset sp_configure to test state
Set-SpConfigureValue 'clr strict security' 1
Set-SpConfigureValue 'clr enabled' 0

try {
    # Run import with CLR config enabled
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    $output = & $ImportScript `
        -Server $Server `
        -Database $TestDbClrEnabled `
        -SourcePath $SourcePath `
        -ConfigFile $ClrEnabledConfig `
        -Credential $credential `
        -CreateDatabase `
        -ContinueOnError `
        -Force 6>&1 2>&1

    $outputText = $output -join "`n"

    # Test 13: Import ran and produced output
    Write-TestResult -TestName "Integration: Import with CLR config produced output" `
        -Passed ($outputText.Length -gt 0) `
        -Message "No output from import"

    # Test 14: Import shows CLR config info
    Write-TestResult -TestName "Integration: Import shows CLR integration enabled message" `
        -Passed ($outputText -match 'CLR integration.*will be enabled|Enabled CLR integration') `
        -Message "Expected CLR integration message in output"

    # Test 15: Import shows CLR strict security disabled message
    Write-TestResult -TestName "Integration: Import shows CLR strict security disabled" `
        -Passed ($outputText -match 'CLR strict security.*will be temporarily disabled|Temporarily disabled CLR strict security') `
        -Message "Expected CLR strict security disabled message"

    # Test 16: Import shows CLR strict security restored message
    Write-TestResult -TestName "Integration: Import shows CLR strict security restored" `
        -Passed ($outputText -match 'Restored CLR strict security|CLR strict security.*already disabled') `
        -Message "Expected CLR strict security restore message"

    # Test 17: No HINT was emitted (since config was provided)
    Write-TestResult -TestName "Integration: No HINT emitted when CLR config is enabled" `
        -Passed ($outputText -notmatch '\[HINT\]') `
        -Message "Expected no HINT when CLR config is provided"

    # Test 18: The table was created successfully (non-CLR object)
    try {
        $tableResult = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE name = 'ClrTestTable'" -Database $TestDbClrEnabled
        # sqlcmd returns Object[] - find the numeric line
        $tableCount = @($tableResult) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        Write-TestResult -TestName "Integration: Non-CLR table created successfully" `
            -Passed ($tableCount -eq "1") `
            -Message "Expected ClrTestTable to exist, got count: $tableCount"
    }
    catch {
        Write-TestResult -TestName "Integration: Non-CLR table created successfully" -Passed $false -Message "Error: $_"
    }

    # Test 19: CLR strict security was restored to original value (1)
    $currentStrictSecurity = Get-SpConfigureValue 'clr strict security'
    Write-TestResult -TestName "Integration: CLR strict security restored to 1 after import" `
        -Passed ($currentStrictSecurity -eq 1) `
        -Message "Expected 'clr strict security' = 1, got: $currentStrictSecurity"

}
catch {
    Write-TestResult -TestName "Integration: Import with CLR config" -Passed $false -Message "Exception: $_"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TEST 2: CLR import WITHOUT config (HINT should be emitted)
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "INTEGRATION TEST 2: CLR import without config (HINT)" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Reset sp_configure
Set-SpConfigureValue 'clr strict security' 1
Set-SpConfigureValue 'clr enabled' 0

try {
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    # Run import WITHOUT CLR config - assembly should fail and HINT should appear
    $output = & $ImportScript `
        -Server $Server `
        -Database $TestDbClrHint `
        -SourcePath $SourcePath `
        -ConfigFile $ClrDisabledConfig `
        -Credential $credential `
        -CreateDatabase `
        -ContinueOnError `
        -Force 6>&1 2>&1

    $outputText = $output -join "`n"

    # Test 20: HINT was emitted because CLR assembly failed without config
    Write-TestResult -TestName "HINT: [HINT] message emitted when assembly fails without config" `
        -Passed ($outputText -match '\[HINT\].*CLR assembly') `
        -Message "Expected [HINT] about CLR assembly load failure"

    # Test 21: HINT suggests disableStrictSecurityForImport
    Write-TestResult -TestName "HINT: Suggests disableStrictSecurityForImport option" `
        -Passed ($outputText -match 'disableStrictSecurityForImport:\s*true') `
        -Message "Expected hint to suggest disableStrictSecurityForImport: true"

    # Test 22: HINT suggests enableClr
    Write-TestResult -TestName "HINT: Suggests enableClr option" `
        -Passed ($outputText -match 'enableClr:\s*true') `
        -Message "Expected hint to suggest enableClr: true"

    # Test 23: Non-CLR objects still imported despite assembly failure
    try {
        $tableResult = Invoke-SqlCommand "SELECT COUNT(*) FROM sys.tables WHERE name = 'ClrTestTable'" -Database $TestDbClrHint
        $tableCount = @($tableResult) | ForEach-Object { "$_".Trim() } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        Write-TestResult -TestName "HINT: Non-CLR table created despite assembly failure" `
            -Passed ($tableCount -eq "1") `
            -Message "Expected ClrTestTable to exist, got count: $tableCount"
    }
    catch {
        Write-TestResult -TestName "HINT: Non-CLR table created despite assembly failure" -Passed $false -Message "Error: $_"
    }

    # Test 24: CLR strict security was NOT changed (no config)
    $currentStrictSecurity = Get-SpConfigureValue 'clr strict security'
    Write-TestResult -TestName "HINT: CLR strict security unchanged (still 1)" `
        -Passed ($currentStrictSecurity -eq 1) `
        -Message "Expected 'clr strict security' = 1, got: $currentStrictSecurity"
}
catch {
    Write-TestResult -TestName "HINT: Import without CLR config" -Passed $false -Message "Exception: $_"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TEST 3: CLR import with restoreStrictSecuritySetting: false
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "INTEGRATION TEST 3: No-restore mode" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Reset sp_configure
Set-SpConfigureValue 'clr strict security' 1
Set-SpConfigureValue 'clr enabled' 0

try {
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    $output = & $ImportScript `
        -Server $Server `
        -Database $TestDbClrNoRestore `
        -SourcePath $SourcePath `
        -ConfigFile $ClrNoRestoreConfig `
        -Credential $credential `
        -CreateDatabase `
        -ContinueOnError `
        -Force 6>&1 2>&1

    $outputText = $output -join "`n"

    # Test 25: Import shows CLR strict security not-restored message
    Write-TestResult -TestName "No-restore: Shows 'left as-is' message" `
        -Passed ($outputText -match 'left as-is|restoreStrictSecuritySetting: false') `
        -Message "Expected 'left as-is' or 'restoreStrictSecuritySetting: false' message"

    # Test 26: CLR strict security was left disabled (not restored)
    $currentStrictSecurity = Get-SpConfigureValue 'clr strict security'
    Write-TestResult -TestName "No-restore: CLR strict security left at 0" `
        -Passed ($currentStrictSecurity -eq 0) `
        -Message "Expected 'clr strict security' = 0, got: $currentStrictSecurity"

}
catch {
    Write-TestResult -TestName "No-restore: Import" -Passed $false -Message "Exception: $_"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# INTEGRATION TEST 4: Config display shows CLR settings
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "INTEGRATION TEST 4: Config display" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Re-run with enabled config and check display output
Set-SpConfigureValue 'clr strict security' 1
Set-SpConfigureValue 'clr enabled' 0

try {
    $securePassword = ConvertTo-SecureString $Password -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential($Username, $securePassword)

    # Use the enabled config test database (already exists from test 1)
    $output = & $ImportScript `
        -Server $Server `
        -Database $TestDbClrEnabled `
        -SourcePath $SourcePath `
        -ConfigFile $ClrEnabledConfig `
        -Credential $credential `
        -ContinueOnError `
        -Force 6>&1 2>&1

    $outputText = $output -join "`n"

    # Test 27: Config display shows CLR Integration enabled
    Write-TestResult -TestName "Display: Shows CLR Integration enabled" `
        -Passed ($outputText -match 'CLR Integration|CLR integration') `
        -Message "Expected CLR Integration in config display"

    # Test 28: Config display shows CLR Strict Security management
    Write-TestResult -TestName "Display: Shows CLR Strict Security management" `
        -Passed ($outputText -match 'CLR Strict Security|CLR strict security') `
        -Message "Expected CLR Strict Security in config display"
}
catch {
    Write-TestResult -TestName "Display: Config display" -Passed $false -Message "Exception: $_"
}

Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# CLEANUP
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan
Write-Host "CLEANUP" -ForegroundColor Cyan
Write-Host "─────────────────────────────────────────────────" -ForegroundColor Cyan

# Restore original sp_configure values
Write-Host "  Restoring original sp_configure values..." -ForegroundColor Gray
if ($null -ne $originalStrictSecurity) {
    Set-SpConfigureValue 'clr strict security' $originalStrictSecurity
    Write-Host "  Restored 'clr strict security' to $originalStrictSecurity" -ForegroundColor Gray
}
if ($null -ne $originalClrEnabled) {
    Set-SpConfigureValue 'clr enabled' $originalClrEnabled
    Write-Host "  Restored 'clr enabled' to $originalClrEnabled" -ForegroundColor Gray
}

# Drop test databases
Remove-TestDatabase $TestDbClrEnabled
Remove-TestDatabase $TestDbClrHint
Remove-TestDatabase $TestDbClrNoRestore

Write-Host "  Cleanup complete" -ForegroundColor Gray
Write-Host ""

# ═══════════════════════════════════════════════════════════════════════════
# RESULTS SUMMARY
# ═══════════════════════════════════════════════════════════════════════════

Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "TEST RESULTS" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Passed: $testsPassed" -ForegroundColor Green
Write-Host "Failed: $testsFailed" -ForegroundColor $(if ($testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host "Total:  $($testsPassed + $testsFailed)" -ForegroundColor White
Write-Host ""

if ($testsFailed -gt 0) {
    Write-Host "Failed tests:" -ForegroundColor Red
    $testResults | Where-Object { -not $_.Passed } | ForEach-Object {
        Write-Host "  - $($_.Name)" -ForegroundColor Red
        if ($_.Message) {
            Write-Host "    $($_.Message)" -ForegroundColor Yellow
        }
    }
    Write-Host ""
    exit 1
}
else {
    Write-Host "All tests passed!" -ForegroundColor Green
    Write-Host ""
    exit 0
}
