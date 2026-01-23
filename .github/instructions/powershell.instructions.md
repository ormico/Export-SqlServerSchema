---
applyTo: "**/*.ps1"
---

# PowerShell Coding Standards

**Project**: Export-SqlServerSchema  
**Applies to**: All `.ps1` files in this repository

---

## Quick Reference

| Convention | Example |
|------------|---------|
| Version requirement | `#Requires -Version 7.0` |
| Parameters | `[CmdletBinding()] param(...)` at script level |
| Function names | `Verb-Noun` (approved verbs only) |
| Output to user | `Write-Host` with `[LEVEL]` prefixes |
| Section headers | `Write-ProgressHeader "Section Name"` |
| Script-scoped state | `$script:VariableName` |
| Error handling | `$ErrorActionPreference = 'Stop'` + try/catch |

---

## 1. Script Structure

### 1.1 Required Header

Every script must start with:

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

.EXAMPLE
    # Another usage scenario
    ./Script-Name.ps1 -Param1 value -OtherSwitch

.NOTES
    Requires: List dependencies (SQL Server SMO, etc.)
    Author: Author Name
    Supports: Windows, Linux, macOS
#>
```

### 1.2 CmdletBinding and Parameters

Always use `[CmdletBinding()]` at the script level:

```powershell
[CmdletBinding()]
param(
  [Parameter(Mandatory = $true, HelpMessage = 'Description for Get-Help')]
  [string]$RequiredParam,

  [Parameter(HelpMessage = 'Description')]
  [ValidateSet('Option1', 'Option2', 'Option3')]
  [string]$EnumParam = 'Option1',

  [Parameter(HelpMessage = 'SQL Server credentials')]
  [System.Management.Automation.PSCredential]$Credential,

  [Parameter(HelpMessage = 'Enable optional feature')]
  [switch]$EnableFeature,

  [Parameter(HelpMessage = 'Timeout in seconds (overrides config file)')]
  [int]$Timeout = 0
)
```

**Rules**:
- One parameter per line
- Include `HelpMessage` for all parameters
- Use `ValidateSet` for enumerated values
- Use `ValidateScript` for path validation: `[ValidateScript({ Test-Path $_ -PathType Container })]`
- Provide sensible defaults where appropriate
- Document override behavior in HelpMessage (e.g., "overrides config file")

### 1.3 Script-Level Initialization

After parameters, set up error handling and script-scoped state:

```powershell
$ErrorActionPreference = 'Stop'
$script:LogFile = $null  # Will be set during initialization

# Script-scoped state for cross-function access
$script:Metrics = @{
  timestamp = $null
  duration  = $null
}
```

---

## 2. Function Conventions

### 2.1 Naming

Use PowerShell approved verbs. Common patterns in this project:

| Verb | Usage | Example |
|------|-------|---------|
| `Export-` | Write objects to files | `Export-Tables` |
| `Get-` | Retrieve data/settings | `Get-SqlServerVersion` |
| `Test-` | Boolean checks | `Test-ObjectExcluded` |
| `Write-` | Output to console/log | `Write-ProgressHeader` |
| `Initialize-` | Set up state/directories | `Initialize-OutputDirectory` |
| `Invoke-` | Execute actions | `Invoke-WithRetry` |
| `New-` | Create objects | `New-ScriptingOptions` |
| `Save-` | Persist to storage | `Save-PerformanceMetrics` |
| `Start-`/`Stop-` | Timer/process control | `Start-MetricsTimer` |

**Avoid**: `Ensure-`, `Do-`, `Run-`, `Process-` (use approved alternatives)

### 2.2 Function Structure

```powershell
function Verb-Noun {
  <#
    .SYNOPSIS
        One-line description.
    .DESCRIPTION
        Detailed explanation if needed.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$RequiredParam,

    [Parameter()]
    [string]$OptionalParam = 'default'
  )

  # Implementation
}
```

**Rules**:
- Comment-based help with `.SYNOPSIS` minimum
- Parameters in `param()` block, not inline
- Two spaces for indentation
- Braces on same line as function declaration

### 2.3 Private/Internal Functions

Prefix with underscore for truly internal helpers (rare):

```powershell
function _GetInternalValue {
  # Internal implementation detail
}
```

---

## 3. Console Output

### 3.1 Status Prefixes

Always prefix user-visible output with status level:

```powershell
Write-Host "[SUCCESS] Exported 15 tables" -ForegroundColor Green
Write-Host "[WARNING] Skipped unsupported object type" -ForegroundColor Yellow
Write-Host "[ERROR] Failed to connect to server" -ForegroundColor Red
Write-Host "[INFO] Processing schemas..." -ForegroundColor Cyan
```

| Prefix | Color | Usage |
|--------|-------|-------|
| `[SUCCESS]` | Green | Completed operations |
| `[WARNING]` | Yellow | Non-fatal issues, skipped items |
| `[ERROR]` | Red | Failures |
| `[INFO]` | Cyan/None | Status updates |

### 3.2 Section Headers

Use `Write-ProgressHeader` for major sections:

```powershell
function Write-ProgressHeader {
  param([string]$Label)
  Write-Host ""
  Write-Host "== $Label ==" -ForegroundColor Cyan
}

# Usage
Write-ProgressHeader "Exporting Tables"
```

### 3.3 Progress Reporting

For operations with many items, use milestone-based progress:

```powershell
function Write-ObjectProgress {
  param(
    [int]$Current,
    [int]$Total,
    [string]$ObjectType,
    [int]$MilestonePercent = 10
  )

  if ($Total -eq 0) { return }

  $percent = [Math]::Floor(($Current / $Total) * 100)
  $lastPercent = [Math]::Floor((($Current - 1) / $Total) * 100)

  # Report at 0% and every milestone
  if ($Current -eq 1 -or 
      [Math]::Floor($percent / $MilestonePercent) -gt [Math]::Floor($lastPercent / $MilestonePercent)) {
    Write-Host "  $ObjectType progress: $percent% ($Current of $Total)" -ForegroundColor DarkGray
  }
}
```

### 3.4 Write-Host vs Write-Output

**Use `Write-Host`** for:
- User-facing status messages
- Progress indicators
- Colored output
- Section headers

**Use `Write-Output`** only when:
- Returning data that should be capturable in variables
- Piping to other commands

**Important**: `Write-Output` is captured when script output is assigned to a variable. For user feedback, always use `Write-Host`.

### 3.5 No Unicode or Emojis

**Never use** Unicode glyphs, emojis, or decorative symbols:

```powershell
# WRONG
Write-Host "✅ Export complete"
Write-Host "❌ Failed to connect"

# CORRECT
Write-Host "[SUCCESS] Export complete" -ForegroundColor Green
Write-Host "[ERROR] Failed to connect" -ForegroundColor Red
```

---

## 4. Error Handling

### 4.1 Standard Pattern

```powershell
$ErrorActionPreference = 'Stop'

try {
  # Main logic
  $result = Do-Something
}
catch {
  Write-Host "[ERROR] Operation failed: $_" -ForegroundColor Red
  exit 1
}
```

### 4.2 Detailed Error Logging

For operations that may fail with complex errors:

```powershell
function Write-ExportError {
  param(
    [string]$ObjectType,
    [string]$ObjectName,
    [System.Management.Automation.ErrorRecord]$ErrorRecord,
    [string]$AdditionalContext = ''
  )

  $errorMsg = "Failed to export $ObjectType$(if ($ObjectName) { ": $ObjectName" })"
  Write-Host "[ERROR] $errorMsg" -ForegroundColor Red

  if ($AdditionalContext) {
    Write-Host "  Context: $AdditionalContext" -ForegroundColor Yellow
  }

  # Walk exception chain for debugging
  $currentException = $ErrorRecord.Exception
  while ($null -ne $currentException) {
    Write-Host "  Exception: $($currentException.Message)" -ForegroundColor Yellow
    $currentException = $currentException.InnerException
  }
}
```

### 4.3 Retry Logic

For transient failures (network, Azure throttling):

```powershell
function Invoke-WithRetry {
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$ScriptBlock,
    [int]$MaxAttempts = 3,
    [int]$InitialDelaySeconds = 2,
    [string]$OperationName = 'Operation'
  )

  $attempt = 0
  $delay = $InitialDelaySeconds

  while ($attempt -lt $MaxAttempts) {
    $attempt++
    try {
      return & $ScriptBlock
    }
    catch {
      if ($attempt -lt $MaxAttempts -and (Test-TransientError $_)) {
        Write-Warning "[$OperationName] Attempt $attempt failed, retrying in $delay seconds..."
        Start-Sleep -Seconds $delay
        $delay = $delay * 2  # Exponential backoff
      }
      else {
        throw
      }
    }
  }
}
```

---

## 5. Configuration and State

### 5.1 Script-Scoped Variables

Use `$script:` for state shared across functions:

```powershell
$script:LogFile = $null
$script:Metrics = @{}
$script:Config = @{}

function Set-LogFile {
  param([string]$Path)
  $script:LogFile = $Path
}
```

### 5.2 YAML Configuration

Support YAML config files with JSON schema validation:

```powershell
function Import-YamlConfig {
  param([string]$ConfigPath)

  if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
    Write-Warning "powershell-yaml module not installed. Using defaults."
    return @{}
  }

  $content = Get-Content $ConfigPath -Raw
  return ConvertFrom-Yaml $content
}
```

---

## 6. SMO-Specific Patterns

### 6.1 Connection Setup

```powershell
$serverConn = [Microsoft.SqlServer.Management.Common.ServerConnection]::new($Server)

if ($Credential) {
  $serverConn.LoginSecure = $false
  $serverConn.Login = $Credential.UserName
  $serverConn.SecurePassword = $Credential.Password
}

$serverConn.Connect()
$smoServer = [Microsoft.SqlServer.Management.Smo.Server]::new($serverConn)
$database = $smoServer.Databases[$DatabaseName]
```

### 6.2 Scripting Options

```powershell
function New-ScriptingOptions {
  param(
    [string]$TargetVersion,
    [hashtable]$Overrides = @{}
  )

  $opts = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
  $opts.AllowSystemObjects = $false
  $opts.ScriptBatchTerminator = $true
  $opts.IncludeHeaders = $true
  # ... more defaults

  # Apply overrides
  foreach ($key in $Overrides.Keys) {
    $opts.$key = $Overrides[$key]
  }

  return $opts
}
```

### 6.3 Collection Filtering

Always filter out system objects:

```powershell
$tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject })
$procedures = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject })
```

---

## 7. Testing Patterns

### 7.1 Integration Test Structure

```powershell
# Arrange
$testDb = "TestDb_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
# ... setup

# Act
./Export-SqlServerSchema.ps1 -Server localhost -Database $testDb -OutputPath $outputPath

# Assert
$exportedFiles = Get-ChildItem $outputPath -Recurse -Filter *.sql
if ($exportedFiles.Count -eq 0) {
  Write-Host "[ERROR] No files exported" -ForegroundColor Red
  exit 1
}
Write-Host "[SUCCESS] Exported $($exportedFiles.Count) files" -ForegroundColor Green
```

### 7.2 Docker Compose for SQL Server

Tests use Docker Compose with SQL Server 2022. Credentials in `tests/.env`:

```yaml
services:
  sqlserver:
    image: mcr.microsoft.com/mssql/server:2022-latest
    environment:
      - ACCEPT_EULA=Y
      - SA_PASSWORD=${SA_PASSWORD}
```

---

## 8. Documentation Standards

### 8.1 Inline Comments

Use comments sparingly for non-obvious logic:

```powershell
# Exponential backoff: double the delay for next attempt
$delay = $delay * 2

# Azure SQL throttling error codes (40501, 40613, etc.)
if ($errorMessage -match '40501|40613|49918') {
  $isTransient = $true
}
```

### 8.2 Function Documentation

Minimum `.SYNOPSIS`, add `.DESCRIPTION` for complex functions:

```powershell
function Export-Tables {
  <#
    .SYNOPSIS
        Exports table definitions to SQL files.
    .DESCRIPTION
        Exports each table with its columns, constraints (except FKs), 
        and triggers. Foreign keys are exported separately to handle
        circular dependencies.
    #>
```

---

## 9. Common Anti-Patterns to Avoid

| Anti-Pattern | Correct Approach |
|--------------|------------------|
| `Write-Output "Status message"` | `Write-Host "[INFO] Status message"` |
| `echo "message"` | `Write-Host "[INFO] message"` |
| `function DoSomething` | `function Invoke-Something` |
| `$global:Variable` | `$script:Variable` |
| Plain `throw "error"` | `Write-Host "[ERROR] ..."; throw` |
| Emojis in output | Text prefixes `[SUCCESS]`, `[ERROR]` |
| Magic numbers | Named constants or parameters |
| Long parameter lines | One parameter per line |

---

## 10. File Organization

```
Export-SqlServerSchema/
  Export-SqlServerSchema.ps1    # Main export script
  Import-SqlServerSchema.ps1    # Main import script
  export-import-config.example.yml
  export-import-config.schema.json
  tests/
    run-integration-test.ps1    # Integration test runner
    test-schema.sql             # Test fixtures
    docker-compose.yml          # SQL Server container
  docs/
    *.md                        # Design documents
  .github/
    copilot-instructions.md     # AI assistant rules
    powershell-style.md         # This file
```

---

## References

- [PowerShell Approved Verbs](https://learn.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands)
- [SMO Documentation](https://learn.microsoft.com/en-us/sql/relational-databases/server-management-objects-smo/)
- Project README.md for usage examples
