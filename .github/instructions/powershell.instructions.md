---
description: PowerShell coding standards, best practices, and AI behavior rules for the Export-SqlServerSchema project.
applyTo: "**/*.ps1"
---

# PowerShell Coding Standards & AI Instructions

**Project**: Export-SqlServerSchema  
**Context**: These instructions apply to all PowerShell script generation and modification in this repository.

## 1. AI Code Generation Rules

When generating or editing PowerShell code, you **MUST** follow these rules:

1.  **No Aliases**: Always use full cmdlet names (`Get-ChildItem` not `ls`, `Where-Object` not `?`, `ForEach-Object` not `%`).
2.  **Named Parameters**: Always use named parameters (`Get-Content -Path $x`) instead of positional ones.
3.  **Strict Typing**: Type all parameters and critical variables (`[string]$Path`, `[int]$Count`).
4.  **Error Handling**: Wrap logical blocks in `try/catch` with `$ErrorActionPreference = 'Stop'`.
5.  **Path Handling**: Always use `Join-Path` for constructing file paths. **NEVER** use string concatenation for paths.
6.  **Pipeline Preservation**: In pure utility functions, output objects to the pipeline. In main control scripts, `Write-Host` is permitted for status updates.
7.  **Linting**: Ensure code passes standard PSScriptAnalyzer rules.

---

## 2. Script Structure

### 2.1 Required Header

Every script file must begin with standard metadata to ensure traceability and copyright compliance.

```powershell
#Requires -Version 7.0

<#
.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    One-line description of what the script does.

.DESCRIPTION
    Multi-paragraph detailed description.
    Include supported modes, key features, and important behaviors.

.PARAMETER ParameterName
    Description of what this parameter does.
    Include valid values and examples.

.EXAMPLE
    # Comment explaining what this example does
    ./Script-Name.ps1 -Param1 value -Param2 value

.NOTES
    Requires: List dependencies (SQL Server SMO, etc.)
#>
```

### 2.2 CmdletBinding and Parameters

Always use `[CmdletBinding()]` to enable common parameters like `-Verbose` and `-ErrorAction`.

```powershell
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Description for Get-Help')]
    [string]$RequiredParam,

    [Parameter(HelpMessage = 'Description')]
    [ValidateSet('Option1', 'Option2')]
    [string]$EnumParam = 'Option1',

    [Parameter(HelpMessage = 'SQL Server credentials')]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(HelpMessage = 'Target Database Name')]
    [string]$Database
)
```

### 2.3 Script Initialization

After parameters, set up error handling and script-scoped state.

```powershell
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3.0

# Script-scoped state for cross-function access
$script:Configuration = @{
    LogFile = $null
}
```

---

## 3. Function Conventions

### 3.1 Naming

Use the `Verb-Noun` format with [Approved Verbs](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands).

| Verb | Usage | Example |
|------|-------|---------|
| `Export-` | Write objects to files | `Export-Tables` |
| `Get-` | Retrieve data/settings | `Get-SqlServerVersion` |
| `Test-` | Boolean checks | `Test-ObjectExcluded` |
| `Write-` | Output to console/log | `Write-ProgressHeader` |
| `Initialize-` | Set up state/directories | `Initialize-OutputDirectory` |
| `Invoke-` | Execute actions | `Invoke-WithRetry` |
| `New-` | Create objects | `New-ScriptingOptions` |

**Avoid**: `Ensure-`, `Do-`, `Run-`, `Process-`.

### 3.2 Function Definition

```powershell
function Get-DatabaseObject {
    <#
    .SYNOPSIS
        Retrieves database objects securely.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [Microsoft.SqlServer.Management.Smo.Database]$Database,

        [Parameter()]
        [string]$Filter
    )

    # Implementation
}
```

---

## 4. Console Output & Logging

This project uses specific visual cues for the operator. **Do not use emojis** (✅, ❌) as they may not render in all terminals/logs properly.

| Prefix | Color | Usage |
|--------|-------|-------|
| `[SUCCESS]` | Green | Completed operations |
| `[WARNING]` | Yellow | Non-fatal issues, skipped items |
| `[ERROR]` | Red | Failures |
| `[INFO]` | Cyan/None | Status updates |

**Pattern**:
```powershell
Write-Host "[SUCCESS] Exported 15 tables" -ForegroundColor Green
Write-Host "[WARNING] Skipped unsupported object type" -ForegroundColor Yellow
Write-Host "[ERROR] Connection failed" -ForegroundColor Red
```

**Section Headers**:
```powershell
function Write-ProgressHeader {
    param([string]$Label)
    Write-Host ""
    Write-Host "== $Label ==" -ForegroundColor Cyan
}
```

**Write-Host vs Write-Output**:
- Use `Write-Host` for **user feedback** (color possible).
- Use `Write-Output` (or implicit output) **ONLY** for returning data to the pipeline content.

---

## 5. Error Handling

### 5.1 Standard Pattern

```powershell
$ErrorActionPreference = 'Stop'

try {
    # Main logic
    $result = Invoke-Something
}
catch {
    $msg = "[ERROR] Operation failed: $_"
    Write-Host $msg -ForegroundColor Red
    
    # Log details if verbose
    Write-Verbose $_.Exception.ToString()
    
    exit 1
}
```

### 5.2 Retry Logic

For network or transient operations (Azure, SQL Connections), implement retry logic.

```powershell
function Invoke-WithRetry {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$ScriptBlock,
        [int]$MaxAttempts = 3,
        [int]$DelaySeconds = 2
    )
    # ... Implementation of exponential backoff ...
}
```

---

## 6. Project-Specific Patterns (SMO)

### 6.1 Connection Setup

Always handle both Windows Authentication and SQL Authentication.

```powershell
$serverConn = [Microsoft.SqlServer.Management.Common.ServerConnection]::new($Server)

if ($Credential) {
    $serverConn.LoginSecure = $false
    $serverConn.Login = $Credential.UserName
    $serverConn.SecurePassword = $Credential.Password
}

$serverConn.Connect()
$smoServer = [Microsoft.SqlServer.Management.Smo.Server]::new($serverConn)
```

### 6.2 Scripting Options

Use `New-ScriptingOptions` (helper function in project) to ensure consistent defaults like `IncludeHeaders` and strict SMO versions.

```powershell
$opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
    DriAll = $false
    DriPrimaryKey = $true
    Indexes = $false
}
```

### 6.3 System Object Filtering

**CRITICAL**: Always filter `IsSystemObject` when iterating SMO collections to avoid scripting internal tables.

```powershell
$tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject })
```

---

## 7. Testing (Instructions)

- Integration tests reside in `tests/`.
- Use **Docker Compose** (`docker-compose.yml`) to spin up ephemeral SQL Server instances.
- Generate unique database names per run: `"TestDb_$(Get-Date -Format 'yyyyMMdd_HHmmss')"`.
- Clean up test databases in a `finally` block.

```powershell
# Example Test Act
./Export-SqlServerSchema.ps1 -Server localhost -Database $testDb -OutputPath $outputPath
```

---

## 8. Avoiding Interactive Prompts (CRITICAL for AI Agents)

**CRITICAL**: The Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1 scripts have **mandatory parameters** that will prompt for input if not provided. Interactive prompts **block terminal execution indefinitely** when run by AI agents, wasting time and credits.

### 8.1 NEVER Run Scripts Without Required Parameters

```powershell
# WRONG - Will prompt for Server and Database, blocking the terminal
pwsh -NoProfile -Command "& { . './Export-SqlServerSchema.ps1' }"
& ./Export-SqlServerSchema.ps1
./Import-SqlServerSchema.ps1

# WRONG - Dot-sourcing EXECUTES the script and triggers mandatory parameter prompts
# This is a common mistake when trying to "load functions" from a script
. './Export-SqlServerSchema.ps1'
pwsh -Command ". './Export-SqlServerSchema.ps1'"

# CORRECT - Always provide ALL mandatory parameters
& ./Export-SqlServerSchema.ps1 -Server 'localhost' -Database 'TestDb' -OutputPath './output'
& ./Import-SqlServerSchema.ps1 -Server 'localhost' -Database 'TargetDb' -SourcePath './scripts'

# CORRECT - To check syntax without execution
pwsh -NoProfile -Command "Get-Command './Export-SqlServerSchema.ps1' -Syntax"
```

### 8.2 NEVER Use Get-Credential Interactively

`Get-Credential` displays a GUI/console prompt. Always construct credentials programmatically:

```powershell
# WRONG - Will display interactive credential prompt
$cred = Get-Credential
& ./Export-SqlServerSchema.ps1 -Server 'localhost' -Database 'TestDb' -Credential $cred

# CORRECT - Construct PSCredential from known values
$securePassword = ConvertTo-SecureString 'YourPassword' -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential('sa', $securePassword)
& ./Export-SqlServerSchema.ps1 -Server 'localhost' -Database 'TestDb' -Credential $credential

# BEST - Use environment variables for sensitive values
$securePassword = ConvertTo-SecureString $env:SA_PASSWORD -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential($env:SA_USERNAME, $securePassword)
```

### 8.3 Test Environment Defaults

For this project's test environment (Docker SQL Server), use these defaults:

| Parameter | Value | Source |
|-----------|-------|--------|
| Server | `localhost` or `localhost,1433` | Docker default |
| SA_PASSWORD | `Test@1234` | `tests/.env` file |
| Username | `sa` | SQL Server default |

```powershell
# Standard test invocation pattern
$password = 'Test@1234'  # From tests/.env
$securePassword = ConvertTo-SecureString $password -AsPlainText -Force
$credential = New-Object System.Management.Automation.PSCredential('sa', $securePassword)

& ./Export-SqlServerSchema.ps1 `
    -Server 'localhost' `
    -Database 'TestDb' `
    -OutputPath './test-output' `
    -Credential $credential
```

### 8.4 Config Files Eliminate Parameter Prompts

Use `-ConfigFile` to provide settings via YAML instead of parameters:

```powershell
# Config file can specify server, credentials path, and other settings
& ./Export-SqlServerSchema.ps1 -ConfigFile './test-config.yml'
& ./Import-SqlServerSchema.ps1 -ConfigFile './test-config.yml' -SourcePath './scripts'
```

### 8.5 Required Parameters Reference

**Export-SqlServerSchema.ps1** mandatory parameters:
- `-Server` (string) - SQL Server instance name
- `-Database` (string) - Database name to export

**Import-SqlServerSchema.ps1** mandatory parameters:
- `-Server` (string) - SQL Server instance name  
- `-Database` (string) - Target database name
- `-SourcePath` (string) - Path to exported scripts folder

### 8.6 Subprocess Pattern for Test Scripts

When test scripts need to call Export/Import and capture output:

```powershell
# Pass credentials via environment variables to avoid embedding in command string
$env:TEST_PASSWORD = $Password
$env:TEST_USERNAME = $Username

$cmd = @"
`$securePassword = ConvertTo-SecureString `$env:TEST_PASSWORD -AsPlainText -Force
`$cred = New-Object System.Management.Automation.PSCredential(`$env:TEST_USERNAME, `$securePassword)
& '$scriptPath' -Server '$Server' -Database '$Database' -OutputPath '$OutputPath' -Credential `$cred
"@

$output = pwsh -NoProfile -Command $cmd 2>&1 | Out-String

# Clean up environment variables after use
Remove-Item Env:\TEST_PASSWORD -ErrorAction SilentlyContinue
Remove-Item Env:\TEST_USERNAME -ErrorAction SilentlyContinue
```

---

## 9. Anti-Patterns to Avoid

- **Concatenating Paths**: `"$Dir\$File"` (Wrong) vs `Join-Path $Dir $File` (Right).
- **Silent Failures**: Empty `catch {}` blocks.
- **Global Variables**: Using `$global:Var`. Use `$script:Var` if necessary.
- **Magic Numbers**: Hardcoding IDs or timeouts without named constants or parameters.
- **Assumed Defaults**: Always specify `-Encoding UTF8` (or generic) when writing files if the default isn't guaranteed.
- **Interactive Prompts**: Using `Get-Credential`, `Read-Host`, or omitting mandatory parameters.
- **Omitting Mandatory Parameters**: Calling Export/Import scripts without `-Server` and `-Database`.
