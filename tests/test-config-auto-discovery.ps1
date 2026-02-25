#Requires -Version 7.0

<#
.SYNOPSIS
    Tests config file auto-discovery for Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1.

.DESCRIPTION
    Validates that both scripts auto-discover export-import-config.yml / export-import-config.yaml
    in script directory then current working directory when -ConfigFile is not provided.

    Runs two test groups:
      1. Unit tests: Verify the Resolve-ConfigFile algorithm (search order, file name priority,
         edge cases) without invoking the full scripts.
      2. Integration tests: Invoke the actual scripts with an invalid server so they fail fast,
         then verify the expected [INFO] messages appear in output before the connection attempt.

    Does NOT require SQL Server.

.NOTES
    Issue: #59 - Config file auto-discovery
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir  = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'
$importScript = Join-Path $projectRoot 'Import-SqlServerSchema.ps1'

$script:testsPassed = 0
$script:testsFailed  = 0

# ─────────────────────────────────────────────────────────────────────────────
# Helper
# ─────────────────────────────────────────────────────────────────────────────

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]  $Passed,
        [string]$Message = ''
    )
    if ($Passed) {
        Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    }
    else {
        Write-Host "[FAILED]  $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

# Local copy of Resolve-ConfigFile logic used for isolated unit tests.
# Accepts an explicit $CurrentDir so tests do not have to change $PWD.
# Must stay in sync with the algorithm in both main scripts.
function Invoke-ResolveConfigFile {
    param(
        [string]$ScriptRoot,
        [string]$CurrentDir
    )

    $wellKnownNames = @('export-import-config.yml', 'export-import-config.yaml')
    $searchPaths    = @($ScriptRoot, $CurrentDir)

    foreach ($searchPath in $searchPaths) {
        if (-not $searchPath) { continue }
        foreach ($name in $wellKnownNames) {
            $candidate = Join-Path $searchPath $name
            if (Test-Path $candidate) {
                return $candidate
            }
        }
    }

    return ''
}

# Invokes a script with an intentionally bad server so it fails before connecting
# but after the config auto-discovery messages are emitted.
# Returns all captured output as a single string.
function Invoke-ScriptForOutput {
    param(
        [string]$ScriptPath,
        [hashtable]$ExtraParams = @{},
        [string]$WorkingDirectory = $PWD.Path
    )

    $baseParams = @{
        Server   = 'invalid-server-autodiscovery-test-99999'
        Database = 'TestDb_AutoDiscovery'
    }

    # Export needs -OutputPath; Import needs -SourcePath. Check filename only, not the
    # full path (which contains 'Export-SqlServerSchema' in the directory name).
    if ((Split-Path $ScriptPath -Leaf) -like 'Export-*') {
        $baseParams['OutputPath'] = Join-Path ([System.IO.Path]::GetTempPath()) ('exp_' + [System.Guid]::NewGuid().ToString('N').Substring(0, 6))
    }
    else {
        $sourceDir = Join-Path ([System.IO.Path]::GetTempPath()) ('src_' + [System.Guid]::NewGuid().ToString('N').Substring(0, 6))
        New-Item -ItemType Directory -Path $sourceDir -Force | Out-Null
        $baseParams['SourcePath'] = $sourceDir
    }

    $allParams = $baseParams + $ExtraParams

    # Run in an isolated subprocess so session state from prior script runs cannot
    # interfere with stream capture. Each parameter is JSON-encoded to handle special
    # characters safely. *>&1 in the wrapper redirects Write-Host (stream 6) to the
    # subprocess stdout, which is captured by the parent process via 2>&1.
    $argStr = ($allParams.GetEnumerator() | ForEach-Object {
        "-$($_.Key) $(ConvertTo-Json ($_.Value.ToString()) -Compress)"
    }) -join ' '

    $wrapperPs1 = [System.IO.Path]::GetTempFileName() + '.ps1'
    @"
Set-Location $(ConvertTo-Json $WorkingDirectory -Compress)
try { & $(ConvertTo-Json $ScriptPath -Compress) $argStr *>&1 } catch {}
"@ | Set-Content -Path $wrapperPs1 -Encoding UTF8

    try {
        $output = & pwsh -NoLogo -NonInteractive -File $wrapperPs1 2>&1
        return ($output | ForEach-Object { "$_" }) -join "`n"
    }
    finally {
        Remove-Item $wrapperPs1 -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup
# ─────────────────────────────────────────────────────────────────────────────

$tempRoot      = Join-Path ([System.IO.Path]::GetTempPath()) "cfg-autodiscovery-$([System.Guid]::NewGuid().ToString('N').Substring(0,8))"
$tempScriptDir = Join-Path $tempRoot 'scripts'
$tempCwdDir    = Join-Path $tempRoot 'cwd'
$tempEmptyDir  = Join-Path $tempRoot 'empty'

New-Item -ItemType Directory -Path $tempScriptDir -Force | Out-Null
New-Item -ItemType Directory -Path $tempCwdDir    -Force | Out-Null
New-Item -ItemType Directory -Path $tempEmptyDir  -Force | Out-Null

# ─────────────────────────────────────────────────────────────────────────────
# Test banner
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'CONFIG AUTO-DISCOVERY TESTS' -ForegroundColor Cyan
Write-Host 'Issue #59: export-import-config.yml / .yaml auto-discovery' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan

try {

    # ─────────────────────────────────────────────────────────────────────
    # GROUP 1 — Unit tests: Resolve-ConfigFile algorithm
    # ─────────────────────────────────────────────────────────────────────

    Write-Host ''
    Write-Host '─── Group 1: Resolve-ConfigFile algorithm ──────────────────────' -ForegroundColor Yellow

    # 1. No files anywhere → empty string
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempEmptyDir -CurrentDir $tempEmptyDir
    Write-TestResult 'Returns empty string when no config exists' ($result -eq '')

    # 2. .yml in script directory
    $ymlInScript = Join-Path $tempScriptDir 'export-import-config.yml'
    Set-Content -Path $ymlInScript -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempScriptDir -CurrentDir $tempEmptyDir
    Write-TestResult '.yml found in script directory' ($result -eq $ymlInScript)
    Remove-Item $ymlInScript

    # 3. .yaml in script directory
    $yamlInScript = Join-Path $tempScriptDir 'export-import-config.yaml'
    Set-Content -Path $yamlInScript -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempScriptDir -CurrentDir $tempEmptyDir
    Write-TestResult '.yaml found in script directory' ($result -eq $yamlInScript)
    Remove-Item $yamlInScript

    # 4. .yml in current working directory
    $ymlInCwd = Join-Path $tempCwdDir 'export-import-config.yml'
    Set-Content -Path $ymlInCwd -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempEmptyDir -CurrentDir $tempCwdDir
    Write-TestResult '.yml found in current working directory' ($result -eq $ymlInCwd)
    Remove-Item $ymlInCwd

    # 5. .yaml in current working directory
    $yamlInCwd = Join-Path $tempCwdDir 'export-import-config.yaml'
    Set-Content -Path $yamlInCwd -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempEmptyDir -CurrentDir $tempCwdDir
    Write-TestResult '.yaml found in current working directory' ($result -eq $yamlInCwd)
    Remove-Item $yamlInCwd

    # 6. Script directory takes precedence over CWD
    $ymlInScript = Join-Path $tempScriptDir 'export-import-config.yml'
    $ymlInCwd    = Join-Path $tempCwdDir    'export-import-config.yml'
    Set-Content -Path $ymlInScript -Value 'export: {}' -Encoding UTF8
    Set-Content -Path $ymlInCwd    -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempScriptDir -CurrentDir $tempCwdDir
    Write-TestResult 'Script directory takes precedence over CWD' ($result -eq $ymlInScript)
    Remove-Item $ymlInScript
    Remove-Item $ymlInCwd

    # 7. .yml takes precedence over .yaml in the same directory
    $ymlPath  = Join-Path $tempScriptDir 'export-import-config.yml'
    $yamlPath = Join-Path $tempScriptDir 'export-import-config.yaml'
    Set-Content -Path $ymlPath  -Value 'export: {}' -Encoding UTF8
    Set-Content -Path $yamlPath -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempScriptDir -CurrentDir $tempEmptyDir
    Write-TestResult '.yml takes precedence over .yaml in same directory' ($result -eq $ymlPath)
    Remove-Item $ymlPath
    Remove-Item $yamlPath

    # 8. Empty ScriptRoot is handled safely; CWD still searched
    $ymlInCwd = Join-Path $tempCwdDir 'export-import-config.yml'
    Set-Content -Path $ymlInCwd -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot '' -CurrentDir $tempCwdDir
    Write-TestResult 'Empty ScriptRoot handled safely — CWD still searched' ($result -eq $ymlInCwd)
    Remove-Item $ymlInCwd

    # 9. First-match-wins: .yml in CWD returned when script dir has only .yaml
    $yamlInScript = Join-Path $tempScriptDir 'export-import-config.yaml'
    $ymlInCwd     = Join-Path $tempCwdDir    'export-import-config.yml'
    Set-Content -Path $yamlInScript -Value 'export: {}' -Encoding UTF8
    Set-Content -Path $ymlInCwd     -Value 'export: {}' -Encoding UTF8
    $result = Invoke-ResolveConfigFile -ScriptRoot $tempScriptDir -CurrentDir $tempCwdDir
    # Script dir .yaml should win because script dir is checked first
    Write-TestResult 'Script dir .yaml wins over CWD .yml (script dir priority)' ($result -eq $yamlInScript)
    Remove-Item $yamlInScript
    Remove-Item $ymlInCwd

    # ─────────────────────────────────────────────────────────────────────
    # GROUP 2 — Integration tests: Export-SqlServerSchema.ps1 output
    # ─────────────────────────────────────────────────────────────────────

    Write-Host ''
    Write-Host '─── Group 2: Export-SqlServerSchema.ps1 output messages ────────' -ForegroundColor Yellow

    # 10. No config → "[INFO] No config file found, using defaults"
    $output = Invoke-ScriptForOutput -ScriptPath $exportScript -WorkingDirectory $tempEmptyDir
    $passed = $output -match '\[INFO\] No config file found, using defaults'
    $msg = $passed ? '' : ("Output lines containing [INFO]:`n" + ($output -split "`n" | Where-Object { $_ -match '\[INFO\]' } | Select-Object -First 5 | Out-String))
    Write-TestResult 'Export: [INFO] No config file found, using defaults' $passed $msg

    # 11. Config in CWD → "[INFO] Using config file: ... (auto-discovered)"
    $configInCwd = Join-Path $tempCwdDir 'export-import-config.yml'
    Set-Content -Path $configInCwd -Value 'export: {}' -Encoding UTF8
    $output = Invoke-ScriptForOutput -ScriptPath $exportScript -WorkingDirectory $tempCwdDir
    $passed = $output -match '\[INFO\] Using config file:.+\(auto-discovered\)'
    $msg = $passed ? '' : ("Output:`n" + ($output -split "`n" | Select-Object -First 10 | Out-String))
    Write-TestResult 'Export: [INFO] Using config file ... (auto-discovered) when config in CWD' $passed $msg
    # Auto-discovered message must include the file path
    $passed = $output -match [regex]::Escape($configInCwd)
    Write-TestResult 'Export: Auto-discovered message includes full config file path' $passed
    Remove-Item $configInCwd

    # 12. .yaml extension discovered when .yml absent
    $yamlInCwd = Join-Path $tempCwdDir 'export-import-config.yaml'
    Set-Content -Path $yamlInCwd -Value 'export: {}' -Encoding UTF8
    $output = Invoke-ScriptForOutput -ScriptPath $exportScript -WorkingDirectory $tempCwdDir
    $passed = $output -match '\[INFO\] Using config file:.+export-import-config\.yaml.+\(auto-discovered\)'
    Write-TestResult 'Export: .yaml extension auto-discovered when .yml absent' $passed
    Remove-Item $yamlInCwd

    # 13. Explicit -ConfigFile suppresses auto-discovery message
    $configInCwd    = Join-Path $tempCwdDir  'export-import-config.yml'
    $explicitConfig = Join-Path $tempEmptyDir 'explicit.yml'
    Set-Content -Path $configInCwd    -Value 'export: {}' -Encoding UTF8
    Set-Content -Path $explicitConfig -Value 'export: {}' -Encoding UTF8
    $output = Invoke-ScriptForOutput -ScriptPath $exportScript -WorkingDirectory $tempCwdDir -ExtraParams @{ ConfigFile = $explicitConfig }
    $noAutoMsg    = $output -notmatch '\(auto-discovered\)'
    $noDefaultMsg = $output -notmatch 'No config file found, using defaults'
    Write-TestResult 'Export: Explicit -ConfigFile suppresses auto-discovery message' ($noAutoMsg -and $noDefaultMsg)
    Remove-Item $configInCwd
    Remove-Item $explicitConfig

    # ─────────────────────────────────────────────────────────────────────
    # GROUP 3 — Integration tests: Import-SqlServerSchema.ps1 output
    # ─────────────────────────────────────────────────────────────────────

    Write-Host ''
    Write-Host '─── Group 3: Import-SqlServerSchema.ps1 output messages ────────' -ForegroundColor Yellow

    # 14. No config → "[INFO] No config file found, using defaults"
    $output = Invoke-ScriptForOutput -ScriptPath $importScript -WorkingDirectory $tempEmptyDir
    $passed = $output -match '\[INFO\] No config file found, using defaults'
    $msg = $passed ? '' : ("Output lines containing [INFO]:`n" + ($output -split "`n" | Where-Object { $_ -match '\[INFO\]' } | Select-Object -First 5 | Out-String))
    Write-TestResult 'Import: [INFO] No config file found, using defaults' $passed $msg

    # 15. Config in CWD → "[INFO] Using config file: ... (auto-discovered)"
    $configInCwd = Join-Path $tempCwdDir 'export-import-config.yml'
    Set-Content -Path $configInCwd -Value 'import: {}' -Encoding UTF8
    $output = Invoke-ScriptForOutput -ScriptPath $importScript -WorkingDirectory $tempCwdDir
    $passed = $output -match '\[INFO\] Using config file:.+\(auto-discovered\)'
    $msg = $passed ? '' : ("Output:`n" + ($output -split "`n" | Select-Object -First 10 | Out-String))
    Write-TestResult 'Import: [INFO] Using config file ... (auto-discovered) when config in CWD' $passed $msg
    $passed = $output -match [regex]::Escape($configInCwd)
    Write-TestResult 'Import: Auto-discovered message includes full config file path' $passed
    Remove-Item $configInCwd

    # 16. Explicit -ConfigFile suppresses auto-discovery message
    $configInCwd    = Join-Path $tempCwdDir  'export-import-config.yml'
    $explicitConfig = Join-Path $tempEmptyDir 'explicit-import.yml'
    Set-Content -Path $configInCwd    -Value 'import: {}' -Encoding UTF8
    Set-Content -Path $explicitConfig -Value 'import: {}' -Encoding UTF8
    $output = Invoke-ScriptForOutput -ScriptPath $importScript -WorkingDirectory $tempCwdDir -ExtraParams @{ ConfigFile = $explicitConfig }
    $noAutoMsg     = $output -notmatch '\(auto-discovered\)'
    $noDefaultsMsg = $output -notmatch 'No config file found, using defaults'
    Write-TestResult 'Import: Explicit -ConfigFile suppresses auto-discovery message' ($noAutoMsg -and $noDefaultsMsg)
    Remove-Item $configInCwd
    Remove-Item $explicitConfig

}
finally {
    # Always clean up temp directories
    if (Test-Path $tempRoot) {
        Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'TEST SUMMARY' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

$total = $script:testsPassed + $script:testsFailed
Write-Host "Tests Passed: $($script:testsPassed) / $total" -ForegroundColor $(if ($script:testsFailed -eq 0) { 'Green' } else { 'Yellow' })
Write-Host ''

if ($script:testsFailed -eq 0) {
    Write-Host '[SUCCESS] ALL CONFIG AUTO-DISCOVERY TESTS PASSED!' -ForegroundColor Green
    exit 0
}
else {
    Write-Host "[FAILED] $($script:testsFailed) test(s) failed" -ForegroundColor Red
    exit 1
}
