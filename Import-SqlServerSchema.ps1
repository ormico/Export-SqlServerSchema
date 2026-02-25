#Requires -Version 7.0

<#
.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    Applies SQL Server database schema from exported scripts to a target database.

.DESCRIPTION
    Applies schema scripts in the correct dependency order to recreate database objects on a target server.
    Supports two import modes: Developer (default, schema-only) and Production (full infrastructure).
    Automatically handles foreign key constraints during data imports and validates referential integrity.

.PARAMETER Server
    Target SQL Server instance. Can also be provided via -ServerFromEnv or config file connection.serverFromEnv.
    Examples: 'localhost', 'server\SQLEXPRESS', '192.168.1.100', 'server.database.windows.net'

.PARAMETER Database
    Target database name. Will be created if -CreateDatabase is specified and it doesn't exist.
    Required parameter.

.PARAMETER SourcePath
    Path to the directory containing exported schema files (timestamped folder from Export-SqlServerSchema.ps1).
    Required parameter.

.PARAMETER Credential
    PSCredential object for SQL Server authentication. If not provided, uses integrated Windows authentication.

.PARAMETER ServerFromEnv
    Name of an environment variable containing the SQL Server address. Only used when -Server is
    not explicitly provided. Example: -ServerFromEnv SQLCMD_SERVER

.PARAMETER UsernameFromEnv
    Name of an environment variable containing the SQL authentication username.
    Must be paired with -PasswordFromEnv. Example: -UsernameFromEnv SQLCMD_USER

.PARAMETER PasswordFromEnv
    Name of an environment variable containing the SQL authentication password.
    Must be paired with -UsernameFromEnv. The password is never written to logs or verbose output.
    Example: -PasswordFromEnv SQLCMD_PASSWORD

.PARAMETER TrustServerCertificate
    Trust the SQL Server certificate without validation. Required for containers with self-signed
    certificates. Can also be set via config file (trustServerCertificate: true or
    connection.trustServerCertificate: true). WARNING: Disables server identity verification.

.PARAMETER ImportMode
    Import mode: 'Dev' (default, schema-only) or 'Prod' (full infrastructure with FileGroups, configs).

.PARAMETER ConfigFile
    Path to YAML configuration file with FileGroup mappings and mode-specific settings. Optional.

.PARAMETER CreateDatabase
    If specified, creates the target database if it does not exist. Requires appropriate server-level permissions.

.PARAMETER IncludeData
    If specified, includes data loading from the Data folder. Default is schema only.

.PARAMETER Force
    If specified, skips the check for existing schema and applies all scripts. Use with caution in production.

.PARAMETER ContinueOnError
    If specified, continues applying scripts even if individual scripts fail. Useful for idempotent applications
    where some scripts may fail due to existing objects.

.PARAMETER CommandTimeout
    SQL Server command timeout in seconds for each script execution. Default: 300 (5 minutes).

.PARAMETER Verbose
    Displays verbose output of SQL scripts being executed.

.EXAMPLE
    # Developer mode (default) - schema only, no infrastructure
    ./Import-SqlServerSchema.ps1 -Server localhost -Database DevDb `
        -SourcePath ".\DbScripts\localhost_SourceDb_20251110_120000" -CreateDatabase

    # Production mode - full import with FileGroups and configurations
    ./Import-SqlServerSchema.ps1 -Server prodserver -Database ProdDb `
        -SourcePath ".\DbScripts\localhost_SourceDb_20251110_120000" `
        -ImportMode Prod -ConfigFile ".\prod-config.yml" -CreateDatabase

    # With SQL authentication and data
    $cred = Get-Credential
    ./Import-SqlServerSchema.ps1 -Server localhost -Database TargetDb `
        -SourcePath ".\DbScripts\..." -Credential $cred -IncludeData

    # Continue on errors (idempotent mode)
    ./Import-SqlServerSchema.ps1 -Server localhost -Database TargetDb `
        -SourcePath ".\DbScripts\..." -ContinueOnError

    # Import in a container using environment variables for credentials
    ./Import-SqlServerSchema.ps1 -Server $env:SQLCMD_SERVER -Database TargetDb `
        -SourcePath ".\DbScripts\..." `
        -UsernameFromEnv SQLCMD_USER -PasswordFromEnv SQLCMD_PASSWORD -TrustServerCertificate

.NOTES
    Requires: SQL Server Management Objects (SMO), PowerShell 7.0+
    Optional: powershell-yaml module for YAML config file support
    Author: Zack Moore
    Supports: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
  [Parameter(HelpMessage = 'Target SQL Server instance. Can also be provided via -ServerFromEnv or config connection.serverFromEnv')]
  [string]$Server,

  [Parameter(Mandatory = $true, HelpMessage = 'Target database name')]
  [string]$Database,

  [Parameter(Mandatory = $true, HelpMessage = 'Path to exported schema scripts')]
  [ValidateScript({ Test-Path $_ -PathType Container })]
  [string]$SourcePath,

  [Parameter(HelpMessage = 'SQL Server credentials')]
  [System.Management.Automation.PSCredential]$Credential,

  [Parameter(HelpMessage = 'Create database if it does not exist')]
  [switch]$CreateDatabase,

  [Parameter(HelpMessage = 'Include data loading')]
  [switch]$IncludeData,

  [Parameter(HelpMessage = 'Force apply even if schema exists')]
  [switch]$Force,

  [Parameter(HelpMessage = 'Continue on script errors')]
  [switch]$ContinueOnError,

  [Parameter(HelpMessage = 'Command timeout in seconds (overrides config file)')]
  [int]$CommandTimeout = 0,

  [Parameter(HelpMessage = 'Connection timeout in seconds (overrides config file)')]
  [int]$ConnectionTimeout = 0,

  [Parameter(HelpMessage = 'Show SQL scripts during execution')]
  [switch]$ShowSQL,

  [Parameter(HelpMessage = 'Import mode: Dev (skip infrastructure) or Prod (import everything)')]
  [ValidateSet('Dev', 'Prod')]
  [string]$ImportMode = 'Dev',

  [Parameter(HelpMessage = 'Path to YAML configuration file')]
  [string]$ConfigFile,

  [Parameter(HelpMessage = 'Maximum retry attempts for transient failures (overrides config file)')]
  [int]$MaxRetries = 0,

  [Parameter(HelpMessage = 'Initial retry delay in seconds (overrides config file)')]
  [int]$RetryDelaySeconds = 0,

  [Parameter(HelpMessage = 'Collect performance metrics and save to JSON file')]
  [switch]$CollectMetrics,

  [Parameter(HelpMessage = 'Include only specific object types (overrides config file). Example: Tables,Views,StoredProcedures')]
  [ValidateSet('FileGroups', 'DatabaseConfiguration', 'Schemas', 'Sequences', 'PartitionFunctions', 'PartitionSchemes',
    'Types', 'XmlSchemaCollections', 'Tables', 'ForeignKeys', 'Indexes', 'Defaults', 'Rules',
    'Programmability', 'Views', 'Functions', 'StoredProcedures', 'Synonyms', 'SearchPropertyLists',
    'PlanGuides', 'DatabaseRoles', 'DatabaseUsers', 'WindowsUsers', 'SqlUsers', 'ExternalUsers',
    'CertificateMappedUsers', 'SecurityPolicies', 'Data')]
  [string[]]$IncludeObjectTypes,

  [Parameter(HelpMessage = 'Exclude specific object types (overrides config file). Example: WindowsUsers,SqlUsers')]
  [ValidateSet('FileGroups', 'DatabaseConfiguration', 'Schemas', 'Sequences', 'PartitionFunctions', 'PartitionSchemes',
    'Types', 'XmlSchemaCollections', 'Tables', 'ForeignKeys', 'Indexes', 'Defaults', 'Rules',
    'Programmability', 'Views', 'Functions', 'StoredProcedures', 'Synonyms', 'SearchPropertyLists',
    'PlanGuides', 'DatabaseRoles', 'DatabaseUsers', 'WindowsUsers', 'SqlUsers', 'ExternalUsers',
    'CertificateMappedUsers', 'SecurityPolicies', 'Data')]
  [string[]]$ExcludeObjectTypes,

  [Parameter(HelpMessage = 'Exclude specific schemas from import. Example: cdc,staging')]
  [string[]]$ExcludeSchemas,

  [Parameter(HelpMessage = 'Strip FILESTREAM features (removes FILESTREAM_ON clauses, converts FILESTREAM columns to VARBINARY(MAX)). Required for Linux/container targets.')]
  [switch]$StripFilestream,

  [Parameter(HelpMessage = 'Strip Always Encrypted features (removes ENCRYPTED WITH clauses from columns, skips Column Master Key and Column Encryption Key creation). Required for targets without access to external key stores.')]
  [switch]$StripAlwaysEncrypted,

  [Parameter(HelpMessage = 'Show required encryption secrets for this export and generate suggested YAML config, then exit without importing')]
  [switch]$ShowRequiredSecrets,

  [Parameter(HelpMessage = 'Environment variable name containing the server address (e.g., -ServerFromEnv SQLCMD_SERVER)')]
  [string]$ServerFromEnv,

  [Parameter(HelpMessage = 'Environment variable name containing the username (e.g., -UsernameFromEnv SQLCMD_USER)')]
  [string]$UsernameFromEnv,

  [Parameter(HelpMessage = 'Environment variable name containing the password (e.g., -PasswordFromEnv SQLCMD_PASSWORD)')]
  [string]$PasswordFromEnv,

  [Parameter(HelpMessage = 'Trust the SQL Server certificate without validation. Required for containers with self-signed certificates.')]
  [switch]$TrustServerCertificate
)

$ErrorActionPreference = if ($ContinueOnError) { 'Continue' } else { 'Stop' }
$script:LogFile = $null  # Will be set during import

# Store IncludeObjectTypes parameter at script level for use in Get-ScriptFiles
$script:IncludeObjectTypesFilter = $IncludeObjectTypes

# Store ExcludeObjectTypes parameter at script level for use in Get-ScriptFiles
$script:ExcludeObjectTypesFilter = $ExcludeObjectTypes

# Store ExcludeSchemas parameter at script level for use in Test-ScriptExcluded
$script:ExcludeSchemasFilter = $ExcludeSchemas

# Store StripFilestream parameter at script level for use in transformations
$script:StripFilestreamEnabled = $StripFilestream.IsPresent

# Store StripAlwaysEncrypted parameter at script level for use in transformations
$script:StripAlwaysEncryptedEnabled = $StripAlwaysEncrypted.IsPresent

# Error tracking for improved reporting (Bug 3 fix)
# Stores final failures (not temporary retry failures) for summary display
$script:FailedScripts = [System.Collections.ArrayList]::new()
$script:LastScriptError = $null  # Stores last error from Invoke-SqlScript for caller access

# Performance metrics tracking (when -CollectMetrics is used)
$script:Metrics = @{
  timestamp                = $null
  phase                    = 'phase1.5'
  server                   = $null
  database                 = $null
  sourcePath               = $null
  importMode               = $null
  totalDurationSeconds     = 0.0
  initializationSeconds    = 0.0
  connectionTimeSeconds    = 0.0
  preliminaryChecksSeconds = 0.0
  scriptCollectionSeconds  = 0.0
  scriptExecutionSeconds   = 0.0
  fkDisableSeconds         = 0.0
  fkEnableSeconds          = 0.0
  scriptsProcessed         = 0
  scriptsSucceeded         = 0
  scriptsFailed            = 0
  scriptsSkipped           = 0
  dataScriptsCount         = 0
  nonDataScriptsCount      = 0
}
$script:ImportStopwatch = $null
$script:InitStopwatch = $null
$script:ConnectionStopwatch = $null
$script:PrelimStopwatch = $null
$script:ScriptCollectStopwatch = $null
$script:ScriptStopwatch = $null
$script:FKStopwatch = $null

#region Credential Resolution from Environment Variables

function Resolve-EnvCredential {
  <#
    .SYNOPSIS
        Resolves credential and connection parameters from environment variables.
    .DESCRIPTION
        Builds a PSCredential from environment variable names specified via *FromEnv parameters
        or config file connection section. Follows precedence:
          1. Explicit -Credential / -Server command-line parameters (highest)
          2. *FromEnv command-line parameters
          3. Config file connection: section
          4. Defaults (Windows auth, no overrides)
    .OUTPUTS
        Hashtable with resolved Server, Credential, and TrustServerCertificate values.
  #>
  param(
    [string]$ServerParam,
    [pscredential]$CredentialParam,
    [string]$ServerFromEnvParam,
    [string]$UsernameFromEnvParam,
    [string]$PasswordFromEnvParam,
    [bool]$TrustServerCertificateParam,
    [hashtable]$Config,
    [hashtable]$BoundParameters
  )

  $result = @{
    Server                 = $ServerParam
    Credential             = $CredentialParam
    TrustServerCertificate = $TrustServerCertificateParam
  }

  # --- Resolve TrustServerCertificate ---
  # CLI switch > config connection section > config root-level > default (false)
  if (-not $BoundParameters.ContainsKey('TrustServerCertificate')) {
    if ($Config -and $Config.ContainsKey('connection') -and $Config.connection -is [System.Collections.IDictionary]) {
      if ($Config.connection.ContainsKey('trustServerCertificate')) {
        $result.TrustServerCertificate = [bool]$Config.connection.trustServerCertificate
      }
    }
    # Also check root-level trustServerCertificate (existing config pattern)
    if (-not $result.TrustServerCertificate -and $Config -and $Config.ContainsKey('trustServerCertificate')) {
      $result.TrustServerCertificate = [bool]$Config.trustServerCertificate
    }
  }

  # --- Resolve Server from env ---
  # CLI -Server > -ServerFromEnv > config connection.serverFromEnv
  if (-not $BoundParameters.ContainsKey('Server') -or [string]::IsNullOrWhiteSpace($ServerParam)) {
    $serverEnvName = $ServerFromEnvParam
    if (-not $serverEnvName -and $Config -and $Config.ContainsKey('connection') -and $Config.connection -is [System.Collections.IDictionary]) {
      if ($Config.connection.ContainsKey('serverFromEnv')) {
        $serverEnvName = $Config.connection.serverFromEnv
      }
    }

    if ($serverEnvName) {
      $envValue = [System.Environment]::GetEnvironmentVariable($serverEnvName)
      if ([string]::IsNullOrWhiteSpace($envValue)) {
        throw "Environment variable '$serverEnvName' (specified via ServerFromEnv) is not set or is empty."
      }
      $result.Server = $envValue
      Write-Verbose "[ENV] Server resolved from environment variable '$serverEnvName'"
    }
  }

  # --- Resolve Credential from env ---
  # CLI -Credential > *FromEnv params > config connection.*FromEnv
  if (-not $BoundParameters.ContainsKey('Credential') -or $null -eq $CredentialParam) {
    $usernameEnvName = $UsernameFromEnvParam
    $passwordEnvName = $PasswordFromEnvParam

    # Fall back to config file connection section
    if ($Config -and $Config.ContainsKey('connection') -and $Config.connection -is [System.Collections.IDictionary]) {
      if (-not $usernameEnvName -and $Config.connection.ContainsKey('usernameFromEnv')) {
        $usernameEnvName = $Config.connection.usernameFromEnv
      }
      if (-not $passwordEnvName -and $Config.connection.ContainsKey('passwordFromEnv')) {
        $passwordEnvName = $Config.connection.passwordFromEnv
      }
    }

    # Both username and password env vars must be specified together
    if ($usernameEnvName -or $passwordEnvName) {
      if (-not $usernameEnvName) {
        throw "PasswordFromEnv is specified but UsernameFromEnv is missing. Both are required for SQL authentication."
      }
      if (-not $passwordEnvName) {
        throw "UsernameFromEnv is specified but PasswordFromEnv is missing. Both are required for SQL authentication."
      }

      $usernameValue = [System.Environment]::GetEnvironmentVariable($usernameEnvName)
      $passwordValue = [System.Environment]::GetEnvironmentVariable($passwordEnvName)

      if ([string]::IsNullOrWhiteSpace($usernameValue)) {
        throw "Environment variable '$usernameEnvName' (specified via UsernameFromEnv) is not set or is empty."
      }
      if ($null -eq $passwordValue -or $passwordValue -eq '') {
        throw "Environment variable '$passwordEnvName' (specified via PasswordFromEnv) is not set or is empty."
      }

      $securePassword = ConvertTo-SecureString $passwordValue -AsPlainText -Force
      $result.Credential = [System.Management.Automation.PSCredential]::new($usernameValue, $securePassword)
      Write-Verbose "[ENV] Credential resolved from environment variables '$usernameEnvName' and '$passwordEnvName'"
    }
  }

  return $result
}

#endregion

#region Helper Functions

function Get-SafeProperty {
  <#
    .SYNOPSIS
        Safely gets a property value from an object (hashtable or PSCustomObject).
    .DESCRIPTION
        Works around PowerShell 7.5+ behavior where accessing non-existent properties
        on hashtables via dot notation throws PropertyNotFoundException.
        This function safely returns $null if the property doesn't exist or if the object is null.
    .PARAMETER Object
        The object to get the property from. Can be null.
    .PARAMETER PropertyName
        The name of the property to retrieve.
    .OUTPUTS
        The property value, or $null if the property doesn't exist or object is null.
  #>
  param(
    [Parameter()]
    $Object,

    [Parameter(Mandatory)]
    [string]$PropertyName
  )

  if ($null -eq $Object) { return $null }

  if ($Object -is [hashtable]) {
    if ($Object.ContainsKey($PropertyName)) {
      return $Object[$PropertyName]
    }
    return $null
  }

  # PSCustomObject or other object types
  if ($Object.PSObject.Properties.Name -contains $PropertyName) {
    return $Object.$PropertyName
  }

  return $null
}

function Export-Metrics {
  <#
    .SYNOPSIS
        Exports collected metrics to a JSON file.
    #>
  param(
    [string]$OutputPath
  )

  if (-not $script:CollectMetrics) { return }

  $script:Metrics.timestamp = (Get-Date).ToString('o')
  $script:Metrics.server = $Server
  $script:Metrics.database = $Database
  $script:Metrics.sourcePath = $SourcePath
  $script:Metrics.importMode = $ImportMode

  $metricsFile = Join-Path $OutputPath "import-metrics-$(Get-Date -Format 'yyyyMMdd_HHmmss').json"
  $script:Metrics | ConvertTo-Json -Depth 10 | Set-Content -Path $metricsFile -Encoding UTF8
  Write-Output "[METRICS] Saved to: $metricsFile"
}

function Write-Log {
  <#
    .SYNOPSIS
        Writes log entry to console and log file.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter()]
    [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
    [string]$Severity = 'INFO'
  )

  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $logEntry = "[$timestamp] [$Severity] $Message"

  # Write to console (consistent with Export script)
  switch ($Severity) {
    'SUCCESS' { Write-Host $Message -ForegroundColor Green }
    'WARNING' { Write-Warning $Message }
    'ERROR' { Write-Host $Message -ForegroundColor Red }
    default { Write-Output $Message }
  }

  # Write to log file if available
  if ($script:LogFile) {
    try {
      Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
    }
    catch {
      # Silently ignore file write errors
    }
  }
}

function Invoke-WithRetry {
  <#
    .SYNOPSIS
        Executes a script block with retry logic for transient failures.
    .DESCRIPTION
        Implements exponential backoff retry strategy for handling transient errors
        like network timeouts, Azure SQL throttling, and connection pool issues.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [scriptblock]$ScriptBlock,

    [Parameter()]
    [int]$MaxAttempts = 3,

    [Parameter()]
    [int]$InitialDelaySeconds = 2,

    [Parameter()]
    [string]$OperationName = 'Operation'
  )

  $attempt = 0
  $delay = $InitialDelaySeconds

  while ($attempt -lt $MaxAttempts) {
    $attempt++

    try {
      Write-Verbose "[$OperationName] Attempt $attempt of $MaxAttempts"
      return & $ScriptBlock
    }
    catch {
      $isTransient = $false
      $errorMessage = $_.Exception.Message

      # Check for transient error patterns
      if ($errorMessage -match 'timeout|timed out|connection.*lost|connection.*closed') {
        $isTransient = $true
        $errorType = 'Network timeout'
      }
      elseif ($errorMessage -match '40501|40613|49918|10928|10929|40197|40540|40143') {
        # Azure SQL throttling error codes
        $isTransient = $true
        $errorType = 'Azure SQL throttling'
      }
      elseif ($errorMessage -match '1205') {
        # Deadlock victim
        $isTransient = $true
        $errorType = 'Deadlock'
      }
      elseif ($errorMessage -match 'pooling|connection pool') {
        $isTransient = $true
        $errorType = 'Connection pool issue'
      }
      elseif ($errorMessage -match '\b(53|233|64)\b') {
        # Transport-level errors (error codes 53, 233, 64)
        $isTransient = $true
        $errorType = 'Transport error'
      }

      if ($isTransient -and $attempt -lt $MaxAttempts) {
        Write-Warning "[$OperationName] $errorType detected on attempt $attempt of $MaxAttempts"
        Write-Warning "  Error: $errorMessage"
        Write-Warning "  Retrying in $delay seconds..."
        Write-Log "$OperationName failed (attempt $attempt): $errorType - $errorMessage" -Severity WARNING

        Start-Sleep -Seconds $delay

        # Exponential backoff: double the delay for next attempt
        $delay = $delay * 2
      }
      else {
        # Non-transient error or final attempt - rethrow
        if ($isTransient) {
          Write-Error "[$OperationName] Failed after $MaxAttempts attempts: $errorMessage"
          Write-Log "$OperationName failed after $MaxAttempts attempts: $errorMessage" -Severity ERROR
        }
        throw
      }
    }
  }
}


function Test-Dependencies {
  <#
    .SYNOPSIS
        Validates that required dependencies are available.
    #>
  Write-Output 'Checking dependencies...'

  # Check PowerShell version
  if ($PSVersionTable.PSVersion.Major -lt 7) {
    throw "PowerShell 7.0 or later required. Current: $($PSVersionTable.PSVersion)"
  }
  Write-Output '[SUCCESS] PowerShell 7.0+'

  # Check for SMO or sqlcmd
  try {
    # Try to import SqlServer module if available
    if (Get-Module -ListAvailable -Name SqlServer) {
      Import-Module SqlServer -ErrorAction Stop
      Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available (SqlServer module)'
      return 'SMO'
    }
    else {
      # Fallback to direct assembly load
      Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
      Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available'
      return 'SMO'
    }
  }
  catch {
    Write-Output '[INFO] SMO not found, will attempt to use sqlcmd'

    try {
      $sqlcmdPath = Get-Command sqlcmd -ErrorAction Stop
      Write-Output "[SUCCESS] sqlcmd available at $($sqlcmdPath.Source)"
      return 'SQLCMD'
    }
    catch {
      throw "Neither SMO nor sqlcmd found. Install SQL Server Management Studio or sqlcmd utility."
    }
  }
}

function Add-FailedScript {
  <#
    .SYNOPSIS
        Records a script failure for error summary reporting.
    .DESCRIPTION
        Adds a failed script entry to the script-level FailedScripts collection.
        These are displayed in the final summary and written to the error log.
    .PARAMETER ScriptName
        Name of the failed script file.
    .PARAMETER ErrorMessage
        The error message (preferably the innermost SQL error).
    .PARAMETER Folder
        The folder the script belongs to (e.g., '09_Tables_PrimaryKey').
    .PARAMETER IsFinal
        Whether this is a final failure (not a temporary retry failure).
  #>
  param(
    [Parameter(Mandatory)]
    [string]$ScriptName,

    [Parameter(Mandatory)]
    [string]$ErrorMessage,

    [string]$Folder = '',

    [bool]$IsFinal = $true
  )

  if (-not $IsFinal) { return }

  # Extract the most useful error message (innermost exception)
  $shortError = $ErrorMessage -split "`n" | Where-Object { $_ -match 'Error \d+:|Message:' } | Select-Object -First 1
  if (-not $shortError) { $shortError = ($ErrorMessage -split "`n")[0] }
  $shortError = $shortError.Trim() -replace '^\s*-?\s*', ''

  [void]$script:FailedScripts.Add([PSCustomObject]@{
    ScriptName   = $ScriptName
    Folder       = $Folder
    ErrorMessage = $shortError
    FullError    = $ErrorMessage
    Timestamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  })
}

function Write-ErrorLog {
  <#
    .SYNOPSIS
        Writes the error log file with all failed scripts.
    .PARAMETER SourcePath
        The source path where the error log will be created.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath
  )

  if ($script:FailedScripts.Count -eq 0) { return $null }

  [string]$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
  [string]$fileName = "import_errors_$timestamp.log"
  $logPath = Join-Path $SourcePath $fileName
  $sb = [System.Text.StringBuilder]::new()

  [void]$sb.AppendLine("Import Error Log - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
  [void]$sb.AppendLine("=" * 80)
  [void]$sb.AppendLine("")

  $index = 1
  foreach ($failure in $script:FailedScripts) {
    [void]$sb.AppendLine("[$index] $($failure.ScriptName)")
    [void]$sb.AppendLine("    Folder: $($failure.Folder)")
    [void]$sb.AppendLine("    Time: $($failure.Timestamp)")
    [void]$sb.AppendLine("    Error: $($failure.ErrorMessage)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("    Full Error Details:")
    foreach ($line in ($failure.FullError -split "`n")) {
      [void]$sb.AppendLine("      $line")
    }
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("-" * 80)
    [void]$sb.AppendLine("")
    $index++
  }

  Set-Content -Path $logPath -Value $sb.ToString() -Encoding UTF8
  return $logPath
}

function Get-TargetServerOS {
  <#
    .SYNOPSIS
        Detects the target SQL Server's operating system (Windows or Linux).
    .PARAMETER Connection
        Optional existing SMO Server connection to reuse. If not provided, creates a temporary SMO connection.
    .NOTES
        Uses SMO connections exclusively to avoid exposing credentials on command line.
    #>
  param(
    [string]$ServerName,
    [pscredential]$Cred,
    [hashtable]$Config,
    [Microsoft.SqlServer.Management.Smo.Server]$Connection
  )

  $query = "SELECT CASE WHEN host_platform = 'Windows' THEN 'Windows' ELSE 'Linux' END AS OS FROM sys.dm_os_host_info"
  $tempConnection = $null

  try {
    # If we have an open SMO connection, use it
    if ($Connection -and $Connection.ConnectionContext.IsOpen) {
      $result = $Connection.ConnectionContext.ExecuteScalar($query)
      Write-Verbose "Target server OS detected via SMO: $result"
      return $result
    }

    # Create temporary SMO connection (avoids exposing password on command line)
    $tempConnection = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
    if ($Cred) {
      $tempConnection.ConnectionContext.set_LoginSecure($false)
      $tempConnection.ConnectionContext.set_Login($Cred.UserName)
      $tempConnection.ConnectionContext.set_SecurePassword($Cred.Password)
    }
    if ($script:TrustServerCertificateEnabled) {
      $tempConnection.ConnectionContext.TrustServerCertificate = $true
    }
    elseif ($Config -and $Config.ContainsKey('trustServerCertificate') -and $Config.trustServerCertificate) {
      $tempConnection.ConnectionContext.TrustServerCertificate = $true
    }
    $tempConnection.ConnectionContext.Connect()

    $result = $tempConnection.ConnectionContext.ExecuteScalar($query)
    Write-Verbose "Target server OS detected via temporary SMO connection: $result"
    return $result
  }
  catch {
    Write-Verbose "Could not detect target OS, assuming Windows: $_"
    return 'Windows'
  }
  finally {
    if ($tempConnection -and $tempConnection.ConnectionContext.IsOpen) {
      $tempConnection.ConnectionContext.Disconnect()
    }
  }
}

function Resolve-SecretValue {
  <#
    .SYNOPSIS
        Resolves a secret value from various sources (env, file, or inline value).
    .DESCRIPTION
        Supports three secret sources:
        - env: Read from environment variable
        - file: Read from file (first line, trailing newline stripped)
        - value: Inline value (development only)
    .PARAMETER SecretConfig
        Hashtable with one of: env, file, or value key
    .PARAMETER SecretName
        Name/identifier of the secret for error messages
    .PARAMETER ImportMode
        Current import mode (Dev or Prod) - warns about inline secrets in Prod
    .OUTPUTS
        The resolved secret string, or $null if resolution fails
  #>
  param(
    [Parameter(Mandatory)]
    [hashtable]$SecretConfig,

    [Parameter(Mandatory)]
    [string]$SecretName,

    [Parameter()]
    [string]$ImportMode = 'Dev'
  )

  # Resolve from environment variable
  if ($SecretConfig.ContainsKey('env')) {
    $envVar = $SecretConfig.env
    $value = [Environment]::GetEnvironmentVariable($envVar)
    if ([string]::IsNullOrEmpty($value)) {
      Write-Warning "[WARNING] Environment variable '$envVar' for secret '$SecretName' is not set or empty"
      return $null
    }
    Write-Verbose "  [SECRET] Resolved '$SecretName' from environment variable: $envVar"
    return $value
  }

  # Resolve from file
  if ($SecretConfig.ContainsKey('file')) {
    $filePath = $SecretConfig.file
    if (-not (Test-Path $filePath)) {
      Write-Warning "[WARNING] Secret file not found for '$SecretName': $filePath"
      return $null
    }
    try {
      # Read first line only, trim trailing newline
      $value = (Get-Content -Path $filePath -First 1 -Raw).TrimEnd("`r`n")
      if ([string]::IsNullOrEmpty($value)) {
        Write-Warning "[WARNING] Secret file is empty for '$SecretName': $filePath"
        return $null
      }
      Write-Verbose "  [SECRET] Resolved '$SecretName' from file: $filePath"
      return $value
    }
    catch {
      Write-Warning "[WARNING] Failed to read secret file for '$SecretName': $_"
      return $null
    }
  }

  # Resolve from inline value
  if ($SecretConfig.ContainsKey('value')) {
    if ($ImportMode -eq 'Prod') {
      Write-Warning "[SECURITY WARNING] Using inline secret value for '$SecretName' in PRODUCTION mode!"
      Write-Warning "  -> Inline secrets should only be used for development/testing"
      Write-Warning "  -> Use 'env:' or 'file:' for production deployments"
    }
    $value = $SecretConfig.value
    if ([string]::IsNullOrEmpty($value)) {
      Write-Warning "[WARNING] Inline secret value is empty for '$SecretName'"
      return $null
    }
    Write-Verbose "  [SECRET] Resolved '$SecretName' from inline value"
    return $value
  }

  Write-Warning "[WARNING] Invalid secret configuration for '$SecretName' - must have 'env', 'file', or 'value' key"
  return $null
}

function Get-EncryptionSecrets {
  <#
    .SYNOPSIS
        Retrieves and resolves all encryption secrets from config.
    .DESCRIPTION
        Resolves encryption secrets for Database Master Key, Symmetric Keys,
        Certificates, and Application Roles from the configuration.
    .PARAMETER ModeSettings
        The mode-specific settings (developerMode or productionMode)
    .PARAMETER ImportMode
        Current import mode (Dev or Prod)
    .OUTPUTS
        Hashtable with resolved secrets, or $null if no secrets configured
  #>
  param(
    [Parameter()]
    [hashtable]$ModeSettings,

    [Parameter()]
    [string]$ImportMode = 'Dev'
  )

  if (-not $ModeSettings -or -not $ModeSettings.ContainsKey('encryptionSecrets')) {
    return $null
  }

  $encryptionConfig = $ModeSettings.encryptionSecrets
  if (-not $encryptionConfig -or $encryptionConfig.Count -eq 0) {
    return $null
  }

  $resolvedSecrets = @{
    databaseMasterKey = $null
    symmetricKeys     = @{}
    certificates      = @{}
    applicationRoles  = @{}
  }

  # Resolve Database Master Key
  if ($encryptionConfig.ContainsKey('databaseMasterKey') -and $encryptionConfig.databaseMasterKey) {
    $resolvedSecrets.databaseMasterKey = Resolve-SecretValue `
      -SecretConfig $encryptionConfig.databaseMasterKey `
      -SecretName 'databaseMasterKey' `
      -ImportMode $ImportMode
  }

  # Resolve Symmetric Keys
  if ($encryptionConfig.ContainsKey('symmetricKeys') -and $encryptionConfig.symmetricKeys) {
    foreach ($keyName in $encryptionConfig.symmetricKeys.Keys) {
      $secretValue = Resolve-SecretValue `
        -SecretConfig $encryptionConfig.symmetricKeys[$keyName] `
        -SecretName "symmetricKey:$keyName" `
        -ImportMode $ImportMode
      if ($secretValue) {
        $resolvedSecrets.symmetricKeys[$keyName] = $secretValue
      }
    }
  }

  # Resolve Certificates
  if ($encryptionConfig.ContainsKey('certificates') -and $encryptionConfig.certificates) {
    foreach ($certName in $encryptionConfig.certificates.Keys) {
      $secretValue = Resolve-SecretValue `
        -SecretConfig $encryptionConfig.certificates[$certName] `
        -SecretName "certificate:$certName" `
        -ImportMode $ImportMode
      if ($secretValue) {
        $resolvedSecrets.certificates[$certName] = $secretValue
      }
    }
  }

  # Resolve Application Roles
  if ($encryptionConfig.ContainsKey('applicationRoles') -and $encryptionConfig.applicationRoles) {
    foreach ($roleName in $encryptionConfig.applicationRoles.Keys) {
      $secretValue = Resolve-SecretValue `
        -SecretConfig $encryptionConfig.applicationRoles[$roleName] `
        -SecretName "applicationRole:$roleName" `
        -ImportMode $ImportMode
      if ($secretValue) {
        $resolvedSecrets.applicationRoles[$roleName] = $secretValue
      }
    }
  }

  return $resolvedSecrets
}

function Get-RequiredEncryptionSecrets {
  <#
    .SYNOPSIS
        Discovers encryption objects in an export.
    .DESCRIPTION
        Reads encryption object information from export metadata file if available,
        otherwise falls back to scanning SQL files for encryption patterns.
        Returns all encryption objects found, including:
        - Password-requiring objects: DMK, symmetric keys, certificates, asymmetric keys, application roles
        - Always Encrypted keys: Column Master Keys and Column Encryption Keys (no passwords needed)

        Fallback scanning includes:
        1. Content scan of all SQL files in 01_Security folder
        2. Full regex-based detection of CREATE statements for encryption objects
        3. Table script scan for ENCRYPTED WITH clauses (detects Always Encrypted from old exports)
    .PARAMETER SourcePath
        Path to the export directory.
    .OUTPUTS
        Hashtable with encryption objects found, or $null if none.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath
  )

  # Try to read from metadata first (fast path)
  $metadata = Read-ExportMetadata -SourcePath $SourcePath
  if ($metadata -and $metadata.ContainsKey('encryptionObjects') -and $metadata.encryptionObjects) {
    Write-Verbose "Reading encryption objects from export metadata"
    return $metadata.encryptionObjects
  }

  # Fallback: scan SQL files for encryption patterns
  Write-Verbose "No encryption metadata found, scanning SQL files..."
  $encryptionObjects = [ordered]@{
    hasDatabaseMasterKey  = $false
    symmetricKeys         = @()
    certificates          = @()
    asymmetricKeys        = @()
    columnMasterKeys      = @()
    columnEncryptionKeys  = @()
    columnMasterKeysInferred = $false
    applicationRoles      = @()
  }

  $securityDir = Join-Path $SourcePath '01_Security'
  if (-not (Test-Path $securityDir)) {
    return $null
  }

  # Scan ALL SQL files in 01_Security for encryption patterns
  # This comprehensive approach handles any filename convention
  $allSecurityFiles = Get-ChildItem -Path $securityDir -Filter '*.sql' -ErrorAction SilentlyContinue
  foreach ($file in $allSecurityFiles) {
    $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
    if (-not $content) { continue }

    # Strip SQL comments to avoid false positives from commented-out code
    $cleanContent = $content -replace '/\*[\s\S]*?\*/', '' -replace '--[^\r\n]*', ''

    # Check for explicit Database Master Key creation
    if (-not $encryptionObjects.hasDatabaseMasterKey -and $cleanContent -match '(?i)CREATE\s+MASTER\s+KEY') {
      $encryptionObjects.hasDatabaseMasterKey = $true
      Write-Verbose "  [ENCRYPTION] DMK found in $($file.Name)"
    }

    # Scan for Symmetric Keys
    $symMatches = [regex]::Matches($cleanContent, 'CREATE\s+SYMMETRIC\s+KEY\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $symMatches) {
      $keyName = $match.Groups[1].Value
      if ($keyName -notin $encryptionObjects.symmetricKeys) {
        $encryptionObjects.symmetricKeys += $keyName
        Write-Verbose "  [ENCRYPTION] Symmetric key '$keyName' found in $($file.Name)"
      }
    }
    # Check for DMK dependency (symmetric key encrypted by master key)
    if (-not $encryptionObjects.hasDatabaseMasterKey -and $cleanContent -match '(?i)ENCRYPTION\s+BY\s+MASTER\s+KEY') {
      $encryptionObjects.hasDatabaseMasterKey = $true
      Write-Verbose "  [ENCRYPTION] DMK inferred from symmetric key referencing MASTER KEY in $($file.Name)"
    }

    # Scan for Certificates
    $certMatches = [regex]::Matches($cleanContent, 'CREATE\s+CERTIFICATE\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $certMatches) {
      $certName = $match.Groups[1].Value
      if ($certName -notin $encryptionObjects.certificates) {
        $encryptionObjects.certificates += $certName
        Write-Verbose "  [ENCRYPTION] Certificate '$certName' found in $($file.Name)"
      }
    }
    # Check for DMK dependency (cert with private key but no explicit password)
    # Split into statements and check each individually to handle multi-cert files
    if (-not $encryptionObjects.hasDatabaseMasterKey) {
      $statements = $cleanContent -split '(?m)^\s*GO\s*$'
      foreach ($stmt in $statements) {
        if ($stmt -match '(?i)WITH\s+PRIVATE\s+KEY(?!\s*\(\s*FILE\s*=)' -and
            $stmt -notmatch '(?i)(ENCRYPTION|DECRYPTION)\s+BY\s+PASSWORD') {
          $encryptionObjects.hasDatabaseMasterKey = $true
          Write-Verbose "  [ENCRYPTION] DMK inferred from certificate with DMK-encrypted private key in $($file.Name)"
          break
        }
      }
    }

    # Scan for Asymmetric Keys
    $asymMatches = [regex]::Matches($cleanContent, 'CREATE\s+ASYMMETRIC\s+KEY\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $asymMatches) {
      $keyName = $match.Groups[1].Value
      if ($keyName -notin $encryptionObjects.asymmetricKeys) {
        $encryptionObjects.asymmetricKeys += $keyName
        Write-Verbose "  [ENCRYPTION] Asymmetric key '$keyName' found in $($file.Name)"
      }
    }

    # Scan for Application Roles
    $roleMatches = [regex]::Matches($cleanContent, 'CREATE\s+APPLICATION\s+ROLE\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $roleMatches) {
      $roleName = $match.Groups[1].Value
      if ($roleName -notin $encryptionObjects.applicationRoles) {
        $encryptionObjects.applicationRoles += $roleName
        Write-Verbose "  [ENCRYPTION] Application role '$roleName' found in $($file.Name)"
      }
    }

    # Scan for Column Master Keys (Always Encrypted)
    $cmkMatches = [regex]::Matches($cleanContent, 'CREATE\s+COLUMN\s+MASTER\s+KEY\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $cmkMatches) {
      $keyName = $match.Groups[1].Value
      if ($keyName -notin $encryptionObjects.columnMasterKeys) {
        $encryptionObjects.columnMasterKeys += $keyName
        Write-Verbose "  [ENCRYPTION] CMK '$keyName' found in $($file.Name)"
      }
    }

    # Scan for Column Encryption Keys (Always Encrypted)
    $cekMatches = [regex]::Matches($cleanContent, 'CREATE\s+COLUMN\s+ENCRYPTION\s+KEY\s+\[?([^\]\s]+)\]?', 'IgnoreCase')
    foreach ($match in $cekMatches) {
      $keyName = $match.Groups[1].Value
      if ($keyName -notin $encryptionObjects.columnEncryptionKeys) {
        $encryptionObjects.columnEncryptionKeys += $keyName
        Write-Verbose "  [ENCRYPTION] CEK '$keyName' found in $($file.Name)"
      }
    }
  }

  # Final fallback: Scan table scripts for ENCRYPTED WITH clauses
  # This detects Always Encrypted usage from old exports that didn't export CMK/CEK separately
  # Column definitions look like: [Column] VARBINARY(xxx) ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [KeyName], ...)
  if ($encryptionObjects.columnMasterKeys.Count -eq 0 -and $encryptionObjects.columnEncryptionKeys.Count -eq 0) {
    $tableDirs = @(
      (Join-Path $SourcePath '09_Tables_PrimaryKey'),
      (Join-Path $SourcePath '10_Tables_ForeignKeys')
    )
    $tableFiles = @()
    foreach ($dir in $tableDirs) {
      if (Test-Path $dir) {
        $tableFiles += Get-ChildItem -Path $dir -Filter '*.sql' -Recurse -ErrorAction SilentlyContinue
      }
    }
    if ($tableFiles.Count -gt 0) {
      Write-Verbose "  [ENCRYPTION] Scanning table scripts for ENCRYPTED WITH clauses..."
      foreach ($file in $tableFiles) {
        $content = Get-Content -Path $file.FullName -Raw -ErrorAction SilentlyContinue
        if (-not $content) { continue }

        # Look for ENCRYPTED WITH (COLUMN_ENCRYPTION_KEY = [KeyName], ENCRYPTION_TYPE = xxx, ALGORITHM = xxx)
        $encryptedColMatches = [regex]::Matches($content, 'ENCRYPTED\s+WITH\s*\(\s*COLUMN_ENCRYPTION_KEY\s*=\s*\[?([^\],\s]+)\]?', 'IgnoreCase')
        foreach ($match in $encryptedColMatches) {
          $cekName = $match.Groups[1].Value
          if ($cekName -notin $encryptionObjects.columnEncryptionKeys) {
            $encryptionObjects.columnEncryptionKeys += $cekName
            Write-Verbose "  [ENCRYPTION] CEK '$cekName' inferred from ENCRYPTED WITH clause in $($file.Name)"
          }
        }
      }

      # If we found CEKs from table columns, mark that CMK exists (CMK is required for any CEK)
      if ($encryptionObjects.columnEncryptionKeys.Count -gt 0 -and $encryptionObjects.columnMasterKeys.Count -eq 0) {
        # We know CMK exists but can't determine the name from table definitions
        $encryptionObjects.columnMasterKeysInferred = $true
        Write-Verbose "  [ENCRYPTION] CMK required (inferred from CEK usage in table columns)"
      }
    }
  }

  # Check if any encryption objects were found
  $hasAny = $encryptionObjects.hasDatabaseMasterKey -or
  $encryptionObjects.symmetricKeys.Count -gt 0 -or
  $encryptionObjects.certificates.Count -gt 0 -or
  $encryptionObjects.asymmetricKeys.Count -gt 0 -or
  $encryptionObjects.columnMasterKeys.Count -gt 0 -or
  $encryptionObjects.columnMasterKeysInferred -or
  $encryptionObjects.columnEncryptionKeys.Count -gt 0 -or
  $encryptionObjects.applicationRoles.Count -gt 0

  if ($hasAny) {
    return $encryptionObjects
  }
  return $null
}

function Show-EncryptionSecretsTemplate {
  <#
    .SYNOPSIS
        Displays required encryption secrets and generates suggested YAML config.
    .DESCRIPTION
        Shows which encryption objects were found in the export and generates
        a ready-to-use YAML configuration template for encryptionSecrets.
    .PARAMETER SourcePath
        Path to the export directory.
    .PARAMETER EncryptionObjects
        Hashtable of encryption objects (from Get-RequiredEncryptionSecrets).
  #>
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath,

    [Parameter(Mandatory)]
    $EncryptionObjects
  )

  $metadata = Read-ExportMetadata -SourcePath $SourcePath

  Write-Host ""
  Write-Host "=" * 70 -ForegroundColor Cyan
  Write-Host "  ENCRYPTION SECRETS REQUIRED FOR IMPORT" -ForegroundColor Cyan
  Write-Host "=" * 70 -ForegroundColor Cyan
  Write-Host ""

  if ($metadata) {
    Write-Host "Export Information:" -ForegroundColor Yellow
    Write-Host "  Source: $($metadata.serverName)\$($metadata.databaseName)"
    Write-Host "  Date:   $($metadata.exportStartTimeUtc)"
    Write-Host ""
  }

  Write-Host "Encryption Objects Found:" -ForegroundColor Yellow

  # Database Master Key
  if ($EncryptionObjects.hasDatabaseMasterKey) {
    Write-Host "  [*] Database Master Key" -ForegroundColor Green
  }

  # Symmetric Keys
  if ($EncryptionObjects.symmetricKeys.Count -gt 0) {
    Write-Host "  [*] Symmetric Keys ($($EncryptionObjects.symmetricKeys.Count)):" -ForegroundColor Green
    foreach ($key in $EncryptionObjects.symmetricKeys) {
      Write-Host "      - $key"
    }
  }

  # Certificates
  if ($EncryptionObjects.certificates.Count -gt 0) {
    Write-Host "  [*] Certificates ($($EncryptionObjects.certificates.Count)):" -ForegroundColor Green
    foreach ($cert in $EncryptionObjects.certificates) {
      Write-Host "      - $cert"
    }
  }

  # Asymmetric Keys
  if ($EncryptionObjects.asymmetricKeys.Count -gt 0) {
    Write-Host "  [*] Asymmetric Keys ($($EncryptionObjects.asymmetricKeys.Count)):" -ForegroundColor Green
    foreach ($key in $EncryptionObjects.asymmetricKeys) {
      Write-Host "      - $key"
    }
  }

  # Column Master Keys (Always Encrypted - no secrets needed)
  if ($EncryptionObjects.columnMasterKeys.Count -gt 0) {
    Write-Host "  [i] Column Master Keys ($($EncryptionObjects.columnMasterKeys.Count)):" -ForegroundColor Cyan
    Write-Host "      (Always Encrypted - keys stored externally, no secrets needed)"
    foreach ($key in $EncryptionObjects.columnMasterKeys) {
      Write-Host "      - $key"
    }
  } elseif ($EncryptionObjects.columnMasterKeysInferred) {
    Write-Host "  [!] Column Master Keys (unknown names):" -ForegroundColor Yellow
    Write-Host "      CMK required (inferred from CEK usage in table columns)."
    Write-Host "      Re-export with current Export-SqlServerSchema.ps1 to get CMK names."
  }

  # Column Encryption Keys (Always Encrypted - no secrets needed)
  if ($EncryptionObjects.columnEncryptionKeys.Count -gt 0) {
    Write-Host "  [i] Column Encryption Keys ($($EncryptionObjects.columnEncryptionKeys.Count)):" -ForegroundColor Cyan
    Write-Host "      (Always Encrypted - encrypted by CMK, no secrets needed)"
    foreach ($key in $EncryptionObjects.columnEncryptionKeys) {
      Write-Host "      - $key"
    }
  }

  # Application Roles
  if ($EncryptionObjects.applicationRoles.Count -gt 0) {
    Write-Host "  [*] Application Roles ($($EncryptionObjects.applicationRoles.Count)):" -ForegroundColor Green
    foreach ($role in $EncryptionObjects.applicationRoles) {
      Write-Host "      - $role"
    }
  }

  Write-Host ""
  Write-Host "-" * 70 -ForegroundColor Gray
  Write-Host "  SUGGESTED YAML CONFIGURATION" -ForegroundColor Cyan
  Write-Host "-" * 70 -ForegroundColor Gray
  Write-Host ""
  Write-Host "Add the following to your config file under 'import.developerMode'" -ForegroundColor Yellow
  Write-Host "or 'import.productionMode' section:" -ForegroundColor Yellow
  Write-Host ""

  # Generate YAML template
  $yamlLines = @()
  $yamlLines += "    encryptionSecrets:"

  if ($EncryptionObjects.hasDatabaseMasterKey) {
    $yamlLines += "      # Database Master Key password"
    $yamlLines += "      databaseMasterKey:"
    $yamlLines += "        env: SQL_DMK_PASSWORD  # Set this environment variable"
    $yamlLines += "        # OR file: /path/to/dmk-secret.txt"
    $yamlLines += "        # OR value: 'DevPassword' (development only!)"
  }

  if ($EncryptionObjects.symmetricKeys.Count -gt 0) {
    $yamlLines += "      "
    $yamlLines += "      # Symmetric Key passwords"
    $yamlLines += "      symmetricKeys:"
    foreach ($key in $EncryptionObjects.symmetricKeys) {
      $envVar = "SQL_SYMKEY_$($key.ToUpper() -replace '[^A-Z0-9]', '_')"
      $yamlLines += "        $($key):"
      $yamlLines += "          env: $envVar"
    }
  }

  if ($EncryptionObjects.certificates.Count -gt 0) {
    $yamlLines += "      "
    $yamlLines += "      # Certificate private key passwords"
    $yamlLines += "      certificates:"
    foreach ($cert in $EncryptionObjects.certificates) {
      $envVar = "SQL_CERT_$($cert.ToUpper() -replace '[^A-Z0-9]', '_')"
      $yamlLines += "        $($cert):"
      $yamlLines += "          env: $envVar"
    }
  }

  if ($EncryptionObjects.asymmetricKeys.Count -gt 0) {
    $yamlLines += "      "
    $yamlLines += "      # Asymmetric Key passwords"
    $yamlLines += "      asymmetricKeys:"
    foreach ($key in $EncryptionObjects.asymmetricKeys) {
      $envVar = "SQL_ASYMKEY_$($key.ToUpper() -replace '[^A-Z0-9]', '_')"
      $yamlLines += "        $($key):"
      $yamlLines += "          env: $envVar"
    }
  }

  if ($EncryptionObjects.applicationRoles.Count -gt 0) {
    $yamlLines += "      "
    $yamlLines += "      # Application Role passwords"
    $yamlLines += "      applicationRoles:"
    foreach ($role in $EncryptionObjects.applicationRoles) {
      $envVar = "SQL_APPROLE_$($role.ToUpper() -replace '[^A-Z0-9]', '_')"
      $yamlLines += "        $($role):"
      $yamlLines += "          env: $envVar"
    }
  }

  # Output YAML with syntax highlighting
  foreach ($line in $yamlLines) {
    if ($line -match '^\s*#') {
      Write-Host $line -ForegroundColor DarkGray
    }
    elseif ($line -match ':\s*$') {
      Write-Host $line -ForegroundColor White
    }
    elseif ($line -match 'env:|file:|value:') {
      Write-Host $line -ForegroundColor Cyan
    }
    else {
      Write-Host $line
    }
  }

  Write-Host ""
  Write-Host "-" * 70 -ForegroundColor Gray
  Write-Host ""
  Write-Host "Secret Source Options:" -ForegroundColor Yellow
  Write-Host "  env:   Environment variable (recommended for CI/CD)" -ForegroundColor Gray
  Write-Host "  file:  File path (recommended for Kubernetes/Docker)" -ForegroundColor Gray
  Write-Host "  value: Inline value (development only, never commit!)" -ForegroundColor Gray
  Write-Host ""
  Write-Host "For more information, see: docs/ENCRYPTION_SECRETS_DESIGN.md" -ForegroundColor DarkGray
  Write-Host ""
}

function Read-ExportMetadata {
  <#
    .SYNOPSIS
        Reads export metadata from _export_metadata.json file.
    .DESCRIPTION
        Loads the metadata file from an export directory to retrieve original
        FileGroup sizes, paths, and other export-time settings.
    .PARAMETER SourcePath
        Path to the export directory containing _export_metadata.json.
    .OUTPUTS
        Hashtable with metadata, or $null if file doesn't exist.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$SourcePath
  )

  $metadataPath = Join-Path $SourcePath '_export_metadata.json'
  if (-not (Test-Path $metadataPath)) {
    Write-Verbose "No export metadata file found at: $metadataPath"
    return $null
  }

  try {
    $json = Get-Content -Path $metadataPath -Raw -Encoding UTF8
    $metadata = $json | ConvertFrom-Json -AsHashtable
    Write-Verbose "Loaded export metadata: version=$($metadata.version), objects=$($metadata.objectCount)"
    return $metadata
  }
  catch {
    Write-Warning "[WARNING] Failed to read export metadata: $_"
    return $null
  }
}

function Get-FileGroupFileSizeValues {
  <#
    .SYNOPSIS
        Gets SIZE and GROWTH values for a FileGroup file.
    .DESCRIPTION
        Resolves file size values with the following priority:
        1. Config file overrides (fileGroupFileSizeDefaults)
        2. Original values from export metadata
        3. Default values (1024KB size, 65536KB growth)
    .PARAMETER FileGroupName
        Name of the FileGroup.
    .PARAMETER FileName
        Original file name within the FileGroup.
    .PARAMETER FgSizeDefaults
        Hashtable with sizeKB and/or fileGrowthKB from config.
    .PARAMETER ExportMetadata
        Hashtable from _export_metadata.json containing original values.
    .OUTPUTS
        Hashtable with SizeKB (int) and GrowthValue (string like "65536KB" or "10%").
  #>
  param(
    [Parameter(Mandatory)]
    [string]$FileGroupName,

    [Parameter(Mandatory)]
    [string]$FileName,

    [Parameter()]
    [hashtable]$FgSizeDefaults,

    [Parameter()]
    [hashtable]$ExportMetadata
  )

  $sizeKB = $null
  $growthValue = $null

  # Priority 1: Config file overrides
  if ($FgSizeDefaults) {
    if ($FgSizeDefaults.sizeKB) { $sizeKB = [int]$FgSizeDefaults.sizeKB }
    if ($FgSizeDefaults.fileGrowthKB) { $growthValue = "$([int]$FgSizeDefaults.fileGrowthKB)KB" }
  }

  # Priority 2: Original values from export metadata
  if (($null -eq $sizeKB -or $null -eq $growthValue) -and $ExportMetadata -and $ExportMetadata.fileGroups) {
    $fgMeta = $ExportMetadata.fileGroups | Where-Object { $_.name -eq $FileGroupName } | Select-Object -First 1
    if ($fgMeta -and $fgMeta.files) {
      $fileMeta = $fgMeta.files | Where-Object { $_.name -eq $FileName } | Select-Object -First 1
      if ($fileMeta) {
        if ($null -eq $sizeKB -and $fileMeta.originalSizeKB) {
          $sizeKB = [int]$fileMeta.originalSizeKB
        }
        if ($null -eq $growthValue) {
          if ($fileMeta.originalGrowthType -eq 'KB' -and $fileMeta.originalGrowthKB) {
            $growthValue = "$([int]$fileMeta.originalGrowthKB)KB"
          }
          elseif ($fileMeta.originalGrowthPct) {
            $growthValue = "$([int]$fileMeta.originalGrowthPct)%"
          }
        }
      }
      else {
        Write-Verbose "  FileGroup '$FileGroupName' file '$FileName' not found in export metadata, using defaults"
      }
    }
    elseif ($fgMeta) {
      Write-Verbose "  FileGroup '$FileGroupName' has no files in export metadata, using defaults"
    }
    else {
      Write-Verbose "  FileGroup '$FileGroupName' not found in export metadata, using defaults"
    }
  }

  # Priority 3: Default values
  if ($null -eq $sizeKB) { $sizeKB = 1024 }        # 1 MB default
  if ($null -eq $growthValue) { $growthValue = '65536KB' }  # 64 MB default

  return @{
    SizeKB      = $sizeKB
    GrowthValue = $growthValue
  }
}

function Get-MemoryOptimizedFileGroupSql {
  <#
    .SYNOPSIS
    Extracts memory-optimized FileGroup creation SQL from a FileGroups script.
    .DESCRIPTION
    Memory-optimized FileGroups cannot be remapped to PRIMARY - they're required infrastructure
    for In-Memory OLTP tables. This function parses the FileGroups SQL file and extracts
    only the blocks for MEMORY_OPTIMIZED_DATA FileGroups.
    .PARAMETER FilePath
    Path to the 001_FileGroups.sql file.
    .OUTPUTS
    Array of SQL blocks for memory-optimized FileGroups, or empty array if none found.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$FilePath
  )

  if (-not (Test-Path $FilePath)) {
    return @()
  }

  $content = Get-Content $FilePath -Raw
  $memoryOptimizedBlocks = @()

  # Split into blocks by GO statements
  $blocks = $content -split '(?m)^GO\s*$'

  $currentType = $null
  $currentBlock = @()

  foreach ($block in $blocks) {
    $trimmedBlock = $block.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedBlock)) { continue }

    # Check if this block defines a FileGroup type
    if ($trimmedBlock -match '-- Type:\s*(MemoryOptimizedDataFileGroup)') {
      $currentType = 'MemoryOptimized'
    }
    elseif ($trimmedBlock -match '-- Type:\s*(RowsFileGroup|FileStreamDataFileGroup)') {
      $currentType = 'Standard'
    }
    elseif ($trimmedBlock -match '-- FileGroup:') {
      # New FileGroup starting, reset type
      $currentType = $null
    }

    # If we're in a memory-optimized context, collect blocks
    if ($currentType -eq 'MemoryOptimized') {
      # Include ADD FILEGROUP and ADD FILE blocks
      if ($trimmedBlock -match 'ADD FILEGROUP.*MEMORY_OPTIMIZED_DATA' -or
          ($trimmedBlock -match 'ALTER DATABASE.*ADD FILE' -and $trimmedBlock -match 'TO FILEGROUP')) {
        $memoryOptimizedBlocks += $trimmedBlock
      }
    }
  }

  return $memoryOptimizedBlocks
}

function Get-DefaultDataPath {
  <#
    .SYNOPSIS
        Gets the SQL Server instance's default data file path.
    .DESCRIPTION
        Queries SERVERPROPERTY('InstanceDefaultDataPath') to get the path where
        SQL Server creates data files by default. Used for auto-remapping FileGroup
        paths in Developer mode.
    .PARAMETER Connection
        SMO Server connection to query.
    #>
  param(
    [Parameter(Mandatory)]
    [Microsoft.SqlServer.Management.Smo.Server]$Connection
  )

  $query = "SELECT CAST(SERVERPROPERTY('InstanceDefaultDataPath') AS NVARCHAR(256))"

  try {
    $result = $Connection.ConnectionContext.ExecuteScalar($query)
    if ($result) {
      # Remove trailing slash if present for consistency
      return $result.TrimEnd('\', '/')
    }
    return $null
  }
  catch {
    Write-Warning "Could not detect default data path: $_"
    return $null
  }
}

function Test-DatabaseConnection {
  <#
    .SYNOPSIS
        Tests connection to target SQL Server.
    .PARAMETER Connection
        Optional existing SMO Server connection to reuse. If not provided, creates a new connection.
    #>
  param(
    [string]$ServerName,
    [pscredential]$Cred,
    [hashtable]$Config,
    [int]$Timeout = 30,
    [Microsoft.SqlServer.Management.Smo.Server]$Connection
  )

  Write-Host "Testing connection to $ServerName..."

  $server = $null
  $ownConnection = $false
  try {
    if ($Connection -and $Connection.ConnectionContext.IsOpen) {
      $server = $Connection
    }
    else {
      $ownConnection = $true
      $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
      $server.ConnectionContext.ConnectTimeout = $Timeout

      # Apply TrustServerCertificate from config if specified
      if ($script:TrustServerCertificateEnabled) {
        $server.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
        $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
      }

      if ($Cred) {
        $server.ConnectionContext.LoginSecure = $false
        $server.ConnectionContext.Login = $Cred.UserName
        $server.ConnectionContext.SecurePassword = $Cred.Password
      }

      $server.ConnectionContext.Connect()
    }
    Write-Host '[SUCCESS] Connection successful' -ForegroundColor Green
    return $true
  }
  catch {
    if ($_.Exception.Message -match 'certificate|SSL|TLS') {
      Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server: $_

This occurs when SQL Server's certificate is not trusted by the client.

RECOMMENDED SOLUTIONS (in order of preference):

1. PRODUCTION: Install a certificate from a trusted CA on SQL Server
   - Obtain a certificate from your organization's CA or a public CA
   - Configure SQL Server to use the trusted certificate
   - This provides full encryption AND server identity verification

2. PRODUCTION: Add the SQL Server certificate to your trusted root store
   - Export the server's certificate and install it on client machines
   - Maintains server identity verification

3. DEVELOPMENT ONLY: Disable certificate validation (SECURITY RISK)
   - Use -TrustServerCertificate switch or add to your config file: trustServerCertificate: true
   - WARNING: This disables server identity verification and allows
     man-in-the-middle attacks. Use ONLY in isolated dev environments.

For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
    }
    else {
      Write-Error "[ERROR] Connection failed: $_"
    }
    return $false
  }
  finally {
    if ($ownConnection -and $server -and $server.ConnectionContext.IsOpen) {
      $server.ConnectionContext.Disconnect()
    }
  }
}

function Test-DatabaseExists {
  <#
    .SYNOPSIS
        Checks if target database exists.
    .PARAMETER Connection
        Optional existing SMO Server connection to reuse. If not provided, creates a new connection.
    #>
  param(
    [string]$ServerName,
    [string]$DatabaseName,
    [pscredential]$Cred,
    [hashtable]$Config,
    [int]$Timeout = 30,
    [Microsoft.SqlServer.Management.Smo.Server]$Connection
  )

  $server = $null
  $ownConnection = $false
  try {
    if ($Connection -and $Connection.ConnectionContext.IsOpen) {
      $server = $Connection
    }
    else {
      $ownConnection = $true
      $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
      if ($Cred) {
        $server.ConnectionContext.LoginSecure = $false
        $server.ConnectionContext.Login = $Cred.UserName
        $server.ConnectionContext.SecurePassword = $Cred.Password
      }

      # Apply TrustServerCertificate from config if specified
      if ($script:TrustServerCertificateEnabled) {
        $server.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
        $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
      }

      $server.ConnectionContext.ConnectTimeout = $Timeout
      $server.ConnectionContext.Connect()
    }
    $exists = $null -ne $server.Databases[$DatabaseName]
    return $exists
  }
  catch {
    Write-Error "[ERROR] Error checking database: $_"
    return $false
  }
  finally {
    if ($ownConnection -and $server -and $server.ConnectionContext.IsOpen) {
      $server.ConnectionContext.Disconnect()
    }
  }
}

function Test-SchemaExists {
  <#
    .SYNOPSIS
        Checks if schema already exists in target database.
    .DESCRIPTION
        Uses a direct SQL query to check for user objects, which is much faster than
        iterating through SMO collections (which triggers full metadata loading).
    .PARAMETER Connection
        Optional existing SMO Server connection to reuse. If not provided, creates a new connection.
    #>
  param(
    [string]$ServerName,
    [string]$DatabaseName,
    [pscredential]$Cred,
    [hashtable]$Config,
    [int]$Timeout = 30,
    [Microsoft.SqlServer.Management.Smo.Server]$Connection
  )

  $server = $null
  $ownConnection = $false
  try {
    if ($Connection -and $Connection.ConnectionContext.IsOpen) {
      $server = $Connection
    }
    else {
      $ownConnection = $true
      $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
      if ($Cred) {
        $server.ConnectionContext.LoginSecure = $false
        $server.ConnectionContext.Login = $Cred.UserName
        $server.ConnectionContext.SecurePassword = $Cred.Password
      }

      # Apply TrustServerCertificate from config if specified
      if ($script:TrustServerCertificateEnabled) {
        $server.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
        $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
      }

      $server.ConnectionContext.ConnectTimeout = $Timeout
      $server.ConnectionContext.Connect()
    }

    $db = $server.Databases[$DatabaseName]
    if ($null -eq $db) {
      return $false
    }

    # Use direct SQL query instead of SMO collection enumeration (MUCH faster)
    # SMO collections trigger full metadata loading which can take 30+ seconds
    # This query checks for user tables, views, or stored procedures in < 0.1s
    $checkQuery = @"
SELECT CASE WHEN EXISTS (
    SELECT 1 FROM sys.objects
    WHERE is_ms_shipped = 0
    AND type IN ('U', 'V', 'P')  -- U=User Table, V=View, P=Stored Procedure
) THEN 1 ELSE 0 END
"@
    $result = $db.ExecuteWithResults($checkQuery)
    $hasObjects = $result.Tables[0].Rows[0][0] -eq 1
    return $hasObjects
  }
  catch {
    Write-Error "[ERROR] Error checking schema: $_"
    return $false
  }
  finally {
    if ($ownConnection -and $server -and $server.ConnectionContext.IsOpen) {
      $server.ConnectionContext.Disconnect()
    }
  }
}

function New-Database {
  <#
    .SYNOPSIS
        Creates a new database on the target server.
    #>
  param(
    [string]$ServerName,
    [string]$DatabaseName,
    [pscredential]$Cred,
    [hashtable]$Config,
    [int]$Timeout = 30
  )

  Write-Host "Creating database $DatabaseName..."

  $server = $null
  try {
    $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
    if ($Cred) {
      $server.ConnectionContext.LoginSecure = $false
      $server.ConnectionContext.Login = $Cred.UserName
      $server.ConnectionContext.SecurePassword = $Cred.Password
    }

    # Apply TrustServerCertificate - resolved from CLI switch, config connection section, or config root
    if ($script:TrustServerCertificateEnabled) {
      $server.ConnectionContext.TrustServerCertificate = $true
    }
    elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
      $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
    }

    $server.ConnectionContext.ConnectTimeout = $Timeout
    $server.ConnectionContext.Connect()

    $db = [Microsoft.SqlServer.Management.Smo.Database]::new($server, $DatabaseName)
    $db.Create()
    Write-Host "[SUCCESS] Database $DatabaseName created" -ForegroundColor Green
    return $true
  }
  catch {
    Write-Error "[ERROR] Failed to create database: $_"
    return $false
  }
  finally {
    if ($server -and $server.ConnectionContext.IsOpen) {
      $server.ConnectionContext.Disconnect()
    }
  }
}

function New-SqlServerConnection {
  <#
    .SYNOPSIS
        Creates a reusable SMO Server connection for script execution.
    .DESCRIPTION
        Creates a single connection that can be reused across multiple Invoke-SqlScript calls
        to avoid connection establishment overhead (typically 100-150ms per connection).
    #>
  param(
    [Parameter(Mandatory)]
    [string]$ServerName,
    [Parameter(Mandatory)]
    [string]$DatabaseName,
    [pscredential]$Cred,
    [int]$Timeout = 300,
    [int]$ConnectionTimeout = 15,
    [hashtable]$Config
  )

  $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
  if ($Cred) {
    $server.ConnectionContext.LoginSecure = $false
    $server.ConnectionContext.Login = $Cred.UserName
    $server.ConnectionContext.SecurePassword = $Cred.Password
  }

  $server.ConnectionContext.ConnectTimeout = $ConnectionTimeout
  $server.ConnectionContext.DatabaseName = $DatabaseName
  $server.ConnectionContext.StatementTimeout = $Timeout

  # Apply TrustServerCertificate - resolved from CLI switch, config connection section, or config root
  if ($script:TrustServerCertificateEnabled) {
    $server.ConnectionContext.TrustServerCertificate = $true
  }
  elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
    $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
  }

  try {
    $server.ConnectionContext.Connect()
    return $server
  }
  catch {
    if ($_.Exception.Message -match 'certificate|SSL|TLS') {
      Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server: $_

This occurs when SQL Server's certificate is not trusted by the client.

RECOMMENDED SOLUTIONS (in order of preference):

1. PRODUCTION: Install a certificate from a trusted CA on SQL Server
2. PRODUCTION: Add the SQL Server certificate to your trusted root store
3. DEVELOPMENT ONLY: Use -TrustServerCertificate switch or add to config file: trustServerCertificate: true
   WARNING: This disables certificate validation - use ONLY in isolated dev environments.

For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
    }
    throw
  }
}

function Invoke-SqlScript {
  <#
    .SYNOPSIS
        Executes a SQL script file or content against the target database.
    .DESCRIPTION
        Accepts either a pre-existing SMO Server connection (for performance) or creates a new one.
        When using a shared connection, the connection is NOT disconnected after script execution.
    #>
  param(
    [string]$FilePath,
    [string]$ScriptContent,
    [string]$ServerName,
    [string]$DatabaseName,
    [pscredential]$Cred,
    [int]$Timeout,
    [switch]$Show,
    [hashtable]$SqlCmdVariables = @{},
    [hashtable]$Config,
    [Microsoft.SqlServer.Management.Smo.Server]$Connection  # Pre-existing connection for reuse
  )

  $ownConnection = $false  # Track if we created the connection (and should disconnect)

  # Determine script source
  if ($ScriptContent) {
    $sql = $ScriptContent
    $scriptName = "(inline script)"
  }
  elseif ($FilePath) {
    if (-not (Test-Path $FilePath)) {
      Write-Warning "Script file not found: $FilePath"
      return $false
    }
    $scriptName = Split-Path -Leaf $FilePath
    $sql = Get-Content $FilePath -Raw
  }
  else {
    Write-Warning "No FilePath or ScriptContent provided"
    return $false
  }

  try {
    if ([string]::IsNullOrWhiteSpace($sql)) {
      Write-Output "  [INFO] Skipped (empty): $scriptName"
      return $true
    }

    # Replace SQLCMD variables in script content
    # Format: $(VariableName) -> value
    foreach ($varName in $SqlCmdVariables.Keys) {
      $varValue = $SqlCmdVariables[$varName]
      $sql = $sql -replace [regex]::Escape("`$($varName)"), $varValue
    }

    # Handle memory-optimized FileGroups - remove SIZE/FILEGROWTH clauses marked for removal
    # Memory-optimized containers don't support SIZE/FILEGROWTH
    if ($sql -match '__MEMORY_OPTIMIZED_REMOVE__') {
      # Remove SIZE = __MEMORY_OPTIMIZED_REMOVE__ and , FILEGROWTH = __MEMORY_OPTIMIZED_REMOVE__
      $sql = $sql -replace ',?\s*SIZE\s*=\s*__MEMORY_OPTIMIZED_REMOVE__', ''
      $sql = $sql -replace ',?\s*FILEGROWTH\s*=\s*__MEMORY_OPTIMIZED_REMOVE__', ''
    }

    # Transform FileGroup references to PRIMARY when using removeToPrimary strategy
    if ($SqlCmdVariables.ContainsKey('__RemapFileGroupsToPrimary__')) {

      # 1. Tables/Indexes: Replace ) ON [FileGroup] with ) ON [PRIMARY]
      #    Pattern: closing paren followed by ON [anything-except-PRIMARY]
      #    Uses (?i) for case-insensitive PRIMARY match (SQL identifiers are case-insensitive)
      $sql = $sql -replace '\)\s*ON\s*\[(?!(?i)PRIMARY\])[^\]]+\]', ') ON [PRIMARY]'

      # 1b. TEXTIMAGE_ON [FileGroup] -> TEXTIMAGE_ON [PRIMARY]
      #     For LOB data (text, ntext, image, varchar(max), etc.)
      $sql = $sql -replace 'TEXTIMAGE_ON\s*\[(?!(?i)PRIMARY\])[^\]]+\]', 'TEXTIMAGE_ON [PRIMARY]'

      # 1c. FILESTREAM_ON [FileGroup] -> FILESTREAM_ON [PRIMARY]
      #     For FILESTREAM data columns
      $sql = $sql -replace 'FILESTREAM_ON\s*\[(?!(?i)PRIMARY\])[^\]]+\]', 'FILESTREAM_ON [PRIMARY]'

      # 2. Partition Schemes (TO ...): Replace TO ([FG1], [FG2], ...) with ALL TO ([PRIMARY])
      #    Pattern: TO ( followed by list of filegroups in brackets
      #    Guard against already-transformed "ALL TO ([PRIMARY])" and PRIMARY-only "TO ([PRIMARY])"
      $sql = $sql -replace '(?<!ALL\s)TO\s*\(\s*(?!\[PRIMARY\]\s*\))\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*\s*\)', 'ALL TO ([PRIMARY])'

      # 3. Partition Schemes (ALL TO ...): Replace ALL TO ([NonPrimary]) with ALL TO ([PRIMARY])
      #    Pattern: ALL TO ([FileGroup]) where FileGroup is not PRIMARY
      $sql = $sql -replace 'ALL\s+TO\s*\(\s*\[(?!PRIMARY\])[^\]]+\]\s*\)', 'ALL TO ([PRIMARY])'
    }

    # Convert login-mapped users to contained users (WITHOUT LOGIN)
    # This allows user creation without requiring server-level logins to exist
    # Transforms: CREATE USER [name] FOR LOGIN [login] -> CREATE USER [name] WITHOUT LOGIN
    if ($SqlCmdVariables.ContainsKey('__ConvertLoginsToContained__')) {
      # Only apply to user scripts
      if ($scriptName -match '\.user\.sql$') {
        # Pattern: FOR LOGIN [loginname] - remove and replace with WITHOUT LOGIN
        # Handle both explicit FOR LOGIN and implicit (username = login name)
        if ($sql -match 'FOR LOGIN\s*\[[^\]]+\]') {
          $sql = $sql -replace '\s*FOR LOGIN\s*\[[^\]]+\]', ' WITHOUT LOGIN'
          Write-Verbose "  [TRANSFORM] Converted login-mapped user to contained user: $scriptName"
        }
        # Handle implicit Windows users: CREATE USER [DOMAIN\User] WITH ... (no FOR LOGIN)
        # These need WITHOUT LOGIN added after the username
        elseif ($sql -match 'CREATE USER\s*\[([^\]]*\\[^\]]*)\]' -and $sql -notmatch 'WITHOUT LOGIN' -and $sql -notmatch 'EXTERNAL PROVIDER') {
          # Insert WITHOUT LOGIN after the user name bracket
          $sql = $sql -replace '(CREATE USER\s*\[[^\]]+\])', '$1 WITHOUT LOGIN'
          Write-Verbose "  [TRANSFORM] Converted implicit Windows user to contained user: $scriptName"
        }
      }
    }

    # Strip FILESTREAM features for Linux/container targets
    # FILESTREAM is Windows-only (requires NTFS integration)
    if ($SqlCmdVariables.ContainsKey('__StripFilestream__')) {
      $originalSql = $sql

      # 1. Remove FILESTREAM_ON clause entirely (can't remap to PRIMARY on Linux - no FILESTREAM support)
      #    Pattern: FILESTREAM_ON [FileGroupName] or FILESTREAM_ON "DEFAULT"
      $sql = $sql -replace '\s*FILESTREAM_ON\s*(\[[^\]]+\]|"DEFAULT")', ''

      # 2. Remove FILESTREAM keyword from column definitions
      #    VARBINARY(MAX) FILESTREAM -> VARBINARY(MAX)
      #    [varbinary](max) FILESTREAM -> [varbinary](max)
      #    Handle with optional brackets and whitespace, preserve rest of column definition
      $sql = $sql -replace '(\[?VARBINARY\]?\s*\(\s*MAX\s*\))\s+FILESTREAM\b', '$1'

      # 3. For FileGroup scripts, remove entire FILESTREAM FileGroup blocks
      #    FileGroup scripts have multiple GO-separated blocks; we need to filter out FILESTREAM blocks
      #    Two-pass approach: first collect FILESTREAM filegroup names, then filter batches referencing them
      if ($scriptName -match '(?i)filegroup' -and $sql -match 'CONTAINS\s+FILESTREAM') {
        # Split by GO statements
        $goPattern = '(?m)^\s*GO\s*$'
        $batches = [regex]::Split($sql, $goPattern)

        # Pass 1: Collect FILESTREAM filegroup names
        $filestreamFileGroups = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

        foreach ($batch in $batches) {
          $trimmedBatch = $batch.Trim()
          if ([string]::IsNullOrWhiteSpace($trimmedBatch)) { continue }

          # Match: ADD FILEGROUP [Name] CONTAINS FILESTREAM
          if ($trimmedBatch -match 'CONTAINS\s+FILESTREAM') {
            if ($trimmedBatch -match 'ADD\s+FILEGROUP\s+\[([^\]]+)\]') {
              [void]$filestreamFileGroups.Add($matches[1])
              Write-Verbose "  [TRANSFORM] Found FILESTREAM FileGroup: $($matches[1])"
            }
          }
          elseif ($trimmedBatch -match '--\s*Type:\s*FileStreamDataFileGroup') {
            # Extract from comment like "-- FileGroup: FG_FILESTREAM"
            if ($trimmedBatch -match '--\s*FileGroup:\s*(\S+)') {
              [void]$filestreamFileGroups.Add($matches[1])
              Write-Verbose "  [TRANSFORM] Found FILESTREAM FileGroup (from comment): $($matches[1])"
            }
          }
        }

        # Pass 2: Filter out FILESTREAM-related batches
        $filteredBatches = @()
        $skippedCount = 0

        foreach ($batch in $batches) {
          $trimmedBatch = $batch.Trim()
          if ([string]::IsNullOrWhiteSpace($trimmedBatch)) { continue }

          $skipBatch = $false

          # Skip batches that create FILESTREAM FileGroups
          if ($trimmedBatch -match '--\s*Type:\s*FileStreamDataFileGroup' -or
              $trimmedBatch -match 'CONTAINS\s+FILESTREAM') {
            $skipBatch = $true
          }

          # Skip batches that ADD FILE to a FILESTREAM FileGroup
          if (-not $skipBatch -and $trimmedBatch -match 'TO\s+FILEGROUP\s+\[([^\]]+)\]') {
            $targetFG = $matches[1]
            if ($filestreamFileGroups.Contains($targetFG)) {
              $skipBatch = $true
              Write-Verbose "  [TRANSFORM] Skipping ADD FILE to FILESTREAM FileGroup [$targetFG]"
            }
          }

          # Skip batches that MODIFY FILEGROUP for a FILESTREAM FileGroup
          if (-not $skipBatch -and $trimmedBatch -match 'MODIFY\s+FILEGROUP\s+\[([^\]]+)\]') {
            $targetFG = $matches[1]
            if ($filestreamFileGroups.Contains($targetFG)) {
              $skipBatch = $true
              Write-Verbose "  [TRANSFORM] Skipping MODIFY FILEGROUP for FILESTREAM FileGroup [$targetFG]"
            }
          }

          if ($skipBatch) {
            $skippedCount++
            Write-Verbose "  [TRANSFORM] Skipping FILESTREAM FileGroup block in: $scriptName"
          }
          else {
            $filteredBatches += $trimmedBatch
          }
        }

        if ($skippedCount -gt 0) {
          Write-Verbose "  [TRANSFORM] Filtered out $skippedCount FILESTREAM block(s) from: $scriptName"
        }

        # Rejoin non-FILESTREAM batches
        if ($filteredBatches.Count -gt 0) {
          $sql = ($filteredBatches -join "`nGO`n") + "`nGO"
        }
        else {
          # All batches were FILESTREAM - skip entire script
          Write-Verbose "  [TRANSFORM] Skipping entire FILESTREAM FileGroup script (no regular FileGroups): $scriptName"
          return $true
        }
      }

      # Log transformation if changes were made
      if ($sql -ne $originalSql) {
        Write-Verbose "  [TRANSFORM] Stripped FILESTREAM features: $scriptName"
      }
    }

    # Strip Always Encrypted features for targets without external key stores
    # Removes ENCRYPTED WITH clauses from column definitions and skips CMK/CEK creation
    if ($SqlCmdVariables.ContainsKey('__StripAlwaysEncrypted__')) {
      $originalSql = $sql

      # Step 1: Strip ENCRYPTED WITH (...) from column definitions
      # Handles single-line (SMO default), multi-line formatting, with/without COLLATE before,
      # in CREATE TABLE and ALTER TABLE ADD, case-insensitive by default in PowerShell -replace
      # Use \s+ before ENCRYPTED to consume whitespace between data type and ENCRYPTED keyword
      $sql = $sql -replace '\s+ENCRYPTED\s+WITH\s*\([^)]+\)', ''

      # Step 2: Remove CMK/CEK batches (CREATE COLUMN MASTER KEY, CREATE COLUMN ENCRYPTION KEY)
      # Split on GO, filter batches containing CMK/CEK creation, rejoin remaining batches
      if ($sql -match 'CREATE\s+COLUMN\s+(MASTER|ENCRYPTION)\s+KEY') {
        $goPattern = '(?m)^\s*GO\s*$'
        $batches = [regex]::Split($sql, $goPattern)
        $filteredBatches = @()
        $skippedCount = 0

        foreach ($batch in $batches) {
          $trimmedBatch = $batch.Trim()
          if ([string]::IsNullOrWhiteSpace($trimmedBatch)) { continue }

          if ($trimmedBatch -match 'CREATE\s+COLUMN\s+MASTER\s+KEY') {
            $skippedCount++
            Write-Verbose "  [TRANSFORM] Skipping CREATE COLUMN MASTER KEY batch: $scriptName"
          }
          elseif ($trimmedBatch -match 'CREATE\s+COLUMN\s+ENCRYPTION\s+KEY') {
            $skippedCount++
            Write-Verbose "  [TRANSFORM] Skipping CREATE COLUMN ENCRYPTION KEY batch: $scriptName"
          }
          else {
            $filteredBatches += $trimmedBatch
          }
        }

        if ($skippedCount -gt 0) {
          Write-Verbose "  [TRANSFORM] Filtered out $skippedCount CMK/CEK batch(es) from: $scriptName"
        }

        if ($filteredBatches.Count -gt 0) {
          $sql = ($filteredBatches -join "`nGO`n") + "`nGO"
        }
        else {
          # All batches were CMK/CEK - skip entire script
          Write-Verbose "  [TRANSFORM] Skipping entire script (all batches are CMK/CEK): $scriptName"
          return $true
        }
      }

      # Step 3: Log transformation if changes were made
      if ($sql -ne $originalSql) {
        Write-Verbose "  [TRANSFORM] Stripped Always Encrypted features: $scriptName"
      }
    }

    # Apply encryption secrets for security objects
    # This injects passwords for Database Master Key, Symmetric Keys, Certificates, and Application Roles
    if ($SqlCmdVariables.ContainsKey('__EncryptionSecrets__')) {
      $secrets = $SqlCmdVariables['__EncryptionSecrets__']
      $originalSql = $sql

      # 1. Application Roles: Handle SMO's dynamic SQL password generation
      #    SMO generates scripts that use sp_executesql with @placeholderPwd variable
      #    We replace the entire dynamic SQL block with a simple CREATE statement
      if ($scriptName -match '\.(approle|role)\.sql$' -and $sql -match 'CREATE\s+APPLICATION\s+ROLE') {
        # Extract role name from the dynamic SQL statement builder
        # Pattern: N'CREATE APPLICATION ROLE [name] WITH ... PASSWORD = N'
        if ($sql -match "CREATE\s+APPLICATION\s+ROLE\s+\[([^\]]+)\]") {
          $roleName = $matches[1]
          if ($secrets.applicationRoles -and $secrets.applicationRoles.ContainsKey($roleName)) {
            $secretPwd = $secrets.applicationRoles[$roleName]
            # Escape single quotes in password for T-SQL string literal
            $escapedPwd = $secretPwd -replace "'", "''"

            # SMO generates dynamic SQL like:
            #   declare @statement nvarchar(4000)
            #   select @statement = N'CREATE APPLICATION ROLE [name] WITH ... PASSWORD = N' + QUOTENAME(@placeholderPwd,'''')
            #   EXEC dbo.sp_executesql @statement
            #
            # We replace the entire script with a simple direct CREATE statement
            # Extract default schema if present
            $defaultSchema = 'dbo'
            if ($sql -match "DEFAULT_SCHEMA\s*=\s*\[([^\]]+)\]") {
              $defaultSchema = $matches[1]
            }

            # Build clean CREATE APPLICATION ROLE statement
            $sql = "CREATE APPLICATION ROLE [$roleName] WITH DEFAULT_SCHEMA = [$defaultSchema], PASSWORD = N'$escapedPwd'`r`nGO"
            Write-Verbose "  [TRANSFORM] Replaced SMO dynamic SQL with direct CREATE for application role: $roleName"
          }
          else {
            Write-Warning "[WARNING] No secret configured for application role: $roleName"
            Write-Warning "  To fix, add to your config file:"
            Write-Warning "    encryptionSecrets:"
            Write-Warning "      applicationRoles:"
            Write-Warning "        $($roleName):"
            Write-Warning "          env: SQL_APPROLE_$($roleName.ToUpper() -replace '[^A-Z0-9]', '_')"
            Write-Warning "  Or run: Import-SqlServerSchema.ps1 -ShowRequiredSecrets ..."
          }
        }
      }

      # 2. Symmetric Keys: CREATE SYMMETRIC KEY [name] ... ENCRYPTION BY PASSWORD = N'...'
      if ($sql -match 'CREATE\s+SYMMETRIC\s+KEY') {
        if ($sql -match 'CREATE\s+SYMMETRIC\s+KEY\s+\[([^\]]+)\]') {
          $keyName = $matches[1]
          if ($secrets.symmetricKeys -and $secrets.symmetricKeys.ContainsKey($keyName)) {
            $secretPwd = $secrets.symmetricKeys[$keyName]
            $escapedPwd = $secretPwd -replace "'", "''"
            # Replace ENCRYPTION BY PASSWORD = N'...' pattern
            $sql = $sql -replace "(ENCRYPTION\s+BY\s+PASSWORD\s*=\s*N?)'[^']*'", "`$1'$escapedPwd'"
            Write-Verbose "  [TRANSFORM] Applied secret for symmetric key: $keyName"
          }
          else {
            Write-Warning "[WARNING] No secret configured for symmetric key: $keyName"
            Write-Warning "  To fix, add to your config file:"
            Write-Warning "    encryptionSecrets:"
            Write-Warning "      symmetricKeys:"
            Write-Warning "        $($keyName):"
            Write-Warning "          env: SQL_SYMKEY_$($keyName.ToUpper() -replace '[^A-Z0-9]', '_')"
            Write-Warning "  Or run: Import-SqlServerSchema.ps1 -ShowRequiredSecrets ..."
          }
        }
      }

      # 3. Certificates with private key password: ENCRYPTION BY PASSWORD = N'...'
      #    Only for certificate scripts (001_Certificates.sql or similar)
      if ($sql -match 'CREATE\s+CERTIFICATE' -and $sql -match 'ENCRYPTION\s+BY\s+PASSWORD') {
        if ($sql -match 'CREATE\s+CERTIFICATE\s+\[([^\]]+)\]') {
          $certName = $matches[1]
          if ($secrets.certificates -and $secrets.certificates.ContainsKey($certName)) {
            $secretPwd = $secrets.certificates[$certName]
            $escapedPwd = $secretPwd -replace "'", "''"
            $sql = $sql -replace "(ENCRYPTION\s+BY\s+PASSWORD\s*=\s*N?)'[^']*'", "`$1'$escapedPwd'"
            Write-Verbose "  [TRANSFORM] Applied secret for certificate: $certName"
          }
          else {
            Write-Warning "[WARNING] No secret configured for certificate private key: $certName"
            Write-Warning "  To fix, add to your config file:"
            Write-Warning "    encryptionSecrets:"
            Write-Warning "      certificates:"
            Write-Warning "        $($certName):"
            Write-Warning "          env: SQL_CERT_$($certName.ToUpper() -replace '[^A-Z0-9]', '_')"
            Write-Warning "  Or run: Import-SqlServerSchema.ps1 -ShowRequiredSecrets ..."
          }
        }
      }

      if ($sql -ne $originalSql) {
        Write-Verbose "  [TRANSFORM] Applied encryption secrets: $scriptName"
      }
    }

    # Replace ALTER DATABASE CURRENT with actual database name
    # CURRENT keyword doesn't work with SMO ExecuteNonQuery
    # Escape the database name to prevent SQL injection via ] characters
    $escapedDbName = Get-EscapedSqlIdentifier -Name $DatabaseName
    $sql = $sql -replace '\bALTER\s+DATABASE\s+CURRENT\b', "ALTER DATABASE [$escapedDbName]"

    # For FileGroups scripts, ensure logical file names are unique by prefixing with database name
    # This prevents conflicts when multiple databases on same server use similar schema
    # Pattern: NAME = N'OriginalName' (but NOT FILENAME = ...)
    # Use negative lookbehind to ensure we're not matching FILENAME
    if ($scriptName -match '(?i)filegroup') {
      # Use a sanitized database name when embedding into T-SQL string literals for logical file names.
      # This prevents quotes or other metacharacters in $DatabaseName from breaking the NAME = N'...' literal.
      $safeDatabaseName = $DatabaseName -replace '[^A-Za-z0-9_]', '_'
      $sql = $sql -replace "(?<!FILE)NAME\s*=\s*N'([^']+)'", "NAME = N'${safeDatabaseName}_`$1'"

      # NOTE: SIZE and FILEGROWTH are now handled via SQLCMD variables ($(FG_NAME_SIZE), $(FG_NAME_GROWTH))
      # populated from export metadata or config file fileGroupFileSizeDefaults
    }

    if ($Show) {
      Write-Output "  >> Executing: $scriptName"
      Write-Output $sql.Substring(0, [Math]::Min(200, $sql.Length)) | Write-Verbose
    }

    # Use existing connection if provided, otherwise create a new one
    $server = $null
    if ($Connection) {
      $server = $Connection
      # Ensure we're connected
      if (-not $server.ConnectionContext.IsOpen) {
        $server.ConnectionContext.Connect()
      }
    }
    else {
      $ownConnection = $true
      $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
      if ($Cred) {
        $server.ConnectionContext.LoginSecure = $false
        $server.ConnectionContext.Login = $Cred.UserName
        $server.ConnectionContext.SecurePassword = $Cred.Password
      }

      $server.ConnectionContext.ConnectTimeout = 15
      $server.ConnectionContext.DatabaseName = $DatabaseName

      # Apply TrustServerCertificate from config if specified
      if ($script:TrustServerCertificateEnabled) {
        $server.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($Config -and $Config.ContainsKey('trustServerCertificate')) {
        $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
      }

      try {
        $server.ConnectionContext.Connect()
      }
      catch {
        if ($_.Exception.Message -match 'certificate|SSL|TLS') {
          Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server for script execution: $_

This occurs when SQL Server's certificate is not trusted by the client.
Failed script: $scriptName

RECOMMENDED SOLUTIONS (in order of preference):

1. PRODUCTION: Install a certificate from a trusted CA on SQL Server
2. PRODUCTION: Add the SQL Server certificate to your trusted root store
3. DEVELOPMENT ONLY: Use -TrustServerCertificate switch or add to config file: trustServerCertificate: true
   WARNING: This disables certificate validation - use ONLY in isolated dev environments.

For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
        }
        throw
      }
    }

    $server.ConnectionContext.StatementTimeout = $Timeout

    # Split by GO statements (batch separator)
    # GO must be on its own line with optional:
    # - Leading/trailing whitespace
    # - Repeat count (GO 5)
    # - Inline comment after GO (GO -- comment)
    # This regex does NOT handle GO inside strings or block comments - caller must ensure clean SQL
    $batches = $sql -split '(?m)^\s*GO\s*(?:\d+)?\s*(?:--.*)?$' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($batch in $batches) {
      $trimmedBatch = $batch.Trim()
      if ($trimmedBatch.Length -gt 0) {
        $server.ConnectionContext.ExecuteNonQuery($trimmedBatch)
      }
    }

    # Only disconnect if we created the connection
    if ($ownConnection -and $server.ConnectionContext.IsOpen) {
      $server.ConnectionContext.Disconnect()
    }

    # Output success message to Verbose stream only (quiet by default for performance)
    Write-Verbose "  [SUCCESS] Applied: $scriptName"
    $script:LastScriptError = $null
    return $true
  }
  catch {
    $errorMessage = "Exception: $($_.Exception.GetType().FullName)`n      Message: $($_.Exception.Message)"

    # Recursively get all inner exceptions
    $currentException = $_.Exception
    $level = 1
    while ($currentException.InnerException) {
      $currentException = $currentException.InnerException
      $errorMessage += "`n      Inner Exception $level (Type: $($currentException.GetType().FullName)):"
      $errorMessage += "`n        Message: $($currentException.Message)"

      # Check for SQL Server specific exceptions at any level
      if ($currentException.GetType().Name -match 'Sql.*Exception') {
        if ($currentException.PSObject.Properties['Errors'] -and $currentException.Errors.Count -gt 0) {
          $errorMessage += "`n        SQL Error Details:"
          foreach ($sqlError in $currentException.Errors) {
            $errorMessage += "`n          - Error $($sqlError.Number): $($sqlError.Message)"
            if ($sqlError.PSObject.Properties['LineNumber']) {
              $errorMessage += "`n            Line $($sqlError.LineNumber)"
            }
          }
        }
      }
      $level++
    }

    # Store error for caller to access (structural scripts need this for error reporting)
    $script:LastScriptError = $errorMessage

    # Use Write-Verbose for retry attempts (failure may be temporary due to dependencies)
    # The calling code will use Write-Error if all retries fail
    Write-Verbose "  [FAILED] $scriptName - will retry if dependency retry enabled`n$errorMessage"
    return -1
  }
}

function Invoke-ScriptsWithDependencyRetries {
  <#
    .SYNOPSIS
        Executes scripts with retry logic to handle cross-object dependencies.

    .DESCRIPTION
        Processes programmability objects (Functions, StoredProcedures, Views) that may have
        cross-type dependencies. Retries failed scripts multiple times, as successful scripts
        may enable previously failing scripts to succeed.

    .PARAMETER Scripts
        Array of script file objects to execute.

    .PARAMETER MaxRetries
        Maximum number of retry attempts (default 3).

    .PARAMETER Server
        SQL Server instance name.

    .PARAMETER Database
        Database name.

    .PARAMETER Credential
        SQL Server credentials.

    .PARAMETER Timeout
        Command timeout in seconds.

    .PARAMETER ShowSQL
        Display SQL statements being executed.

    .PARAMETER SqlCmdVariables
        SQLCMD variables for script substitution.

    .PARAMETER Config
        Configuration object.

    .PARAMETER Connection
        Shared SMO connection object.

    .PARAMETER ContinueOnError
        Continue processing even if scripts fail.

    .PARAMETER MaxAttempts
        Maximum retry attempts for transient failures.

    .PARAMETER InitialDelaySeconds
        Initial retry delay for transient failures.

    .OUTPUTS
        Hashtable with success, failure, and skip counts.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [array]$Scripts,

    [int]$MaxRetries = 3,

    [Parameter(Mandatory = $true)]
    [string]$Server,

    [Parameter(Mandatory = $true)]
    [string]$Database,

    $Credential,
    [int]$Timeout,
    [switch]$ShowSQL,
    [hashtable]$SqlCmdVariables,
    $Config,
    $Connection,
    [switch]$ContinueOnError,
    [int]$MaxAttempts,
    [int]$InitialDelaySeconds
  )

  if ($Scripts.Count -eq 0) {
    return @{ Success = 0; Failure = 0; Skip = 0 }
  }

  Write-Output ''
  Write-Output "[INFO] Processing $($Scripts.Count) programmability object(s) with dependency retry logic (max $MaxRetries retries)..."
  Write-Verbose "[RETRY] Dependency retry enabled for $($Scripts.Count) scripts"

  $successCount = 0
  $failureCount = 0
  $skipCount = 0

  # Start with all scripts as "failed" (pending)
  $pendingScripts = @($Scripts)
  $attempt = 1
  $failedScriptErrors = @{}  # Track last error for each failed script

  while ($pendingScripts.Count -gt 0 -and $attempt -le $MaxRetries) {
    if ($attempt -gt 1) {
      Write-Output "[INFO] Retry attempt $attempt of $MaxRetries - $($pendingScripts.Count) script(s) remaining..."
      Write-Verbose "[RETRY] Attempt $attempt - retrying $($pendingScripts.Count) scripts"
    }

    $stillFailing = @()
    $attemptSuccessCount = 0

    foreach ($scriptFile in $pendingScripts) {
      # Capture errors from script execution
      $ErrorActionPreference = 'Continue'  # Allow retry loop to continue on error
      $scriptError = $null

      try {
        $result = Invoke-WithRetry -MaxAttempts $MaxAttempts -InitialDelaySeconds $InitialDelaySeconds `
          -OperationName "Script: $($scriptFile.Name)" -ScriptBlock {
          Invoke-SqlScript -FilePath $scriptFile.FullName -ServerName $Server `
            -DatabaseName $Database -Cred $Credential -Timeout $Timeout -Show:$ShowSQL `
            -SqlCmdVariables $SqlCmdVariables -Config $Config -Connection $Connection
        } -ErrorVariable scriptError
      }
      catch {
        $result = -1
        # Convert error record to string for consistent error handling
        $scriptError = $_.Exception.Message
        if ($_.Exception.InnerException) {
          $scriptError += "`n  Inner: $($_.Exception.InnerException.Message)"
        }
      }

      $ErrorActionPreference = 'Stop'  # Restore default

      if ($result -eq $true) {
        $successCount++
        $attemptSuccessCount++
        # Remove from error tracking if it succeeded
        if ($failedScriptErrors.ContainsKey($scriptFile.Name)) {
          $failedScriptErrors.Remove($scriptFile.Name)
        }
      }
      elseif ($result -eq -1) {
        # Script failed - add to retry list and track error
        $stillFailing += $scriptFile
        if ($scriptError) {
          $failedScriptErrors[$scriptFile.Name] = $scriptError
        }
      }
      else {
        $skipCount++
      }
    }

    Write-Verbose "[RETRY] Attempt $attempt results: $attemptSuccessCount succeeded, $($stillFailing.Count) failed"

    # Check if we made progress
    if ($attemptSuccessCount -eq 0 -and $stillFailing.Count -gt 0) {
      Write-Warning "[WARNING] No progress in retry attempt $attempt - no scripts succeeded"
      Write-Warning "  Remaining failures likely due to syntax errors, missing references, or permissions"
      break
    }

    $pendingScripts = $stillFailing
    $attempt++
  }

  # Final results
  if ($pendingScripts.Count -gt 0) {
    $failureCount = $pendingScripts.Count
    Write-Output ''
    Write-Host "[ERROR] $failureCount script(s) failed after $MaxRetries retry attempt(s):" -ForegroundColor Red

    foreach ($failedScript in $pendingScripts) {
      # Get the error message for display - ensure it's a string
      $errorMsg = if ($failedScriptErrors.ContainsKey($failedScript.Name)) {
        $rawError = $failedScriptErrors[$failedScript.Name]
        # Convert ErrorRecord or other objects to string
        if ($rawError -is [System.Management.Automation.ErrorRecord]) {
          $rawError.Exception.Message
        } elseif ($rawError -is [string]) {
          $rawError
        } else {
          [string]$rawError
        }
      } else {
        'Unknown error'
      }

      # Extract short error for display
      $shortError = $errorMsg -split "`n" | Where-Object { $_ -match 'Error \d+:|Message:' } | Select-Object -First 1
      if (-not $shortError) { $shortError = ($errorMsg -split "`n")[0] }
      $shortError = $shortError.Trim() -replace '^\s*-?\s*', ''

      Write-Host "  - $($failedScript.Name)" -ForegroundColor Red
      Write-Host "    $shortError" -ForegroundColor DarkRed

      # Record for final summary
      Add-FailedScript -ScriptName $failedScript.Name -ErrorMessage $errorMsg -Folder '14_Programmability' -IsFinal $true
    }

    if (-not $ContinueOnError) {
      # Don't use Write-Error as it terminates before error log can be written
      # Returning failure count allows caller to handle gracefully
      Write-Host "[ERROR] Dependency retry limit reached with $failureCount failed script(s). Aborting import after writing error log." -ForegroundColor Red
    }
  }
  else {
    Write-Output "[SUCCESS] All programmability objects imported successfully"
  }

  return @{
    Success = $successCount
    Failure = $failureCount
    Skip    = $skipCount
  }
}

function Get-EscapedSqlIdentifier {
  <#
    .SYNOPSIS
        Escapes a SQL Server identifier for safe use in bracketed notation.
    .DESCRIPTION
        SQL Server uses square brackets [] to delimit identifiers. To include a literal
        ] character within a bracketed identifier, it must be escaped as ]].
        This function ensures identifiers are safe from second-order SQL injection
        via malicious object names stored in the database.
    .PARAMETER Name
        The identifier name to escape.
    .OUTPUTS
        The escaped identifier name (without surrounding brackets).
    .EXAMPLE
        Get-EscapedSqlIdentifier -Name 'Normal_Name'
        # Returns: Normal_Name
    .EXAMPLE
        Get-EscapedSqlIdentifier -Name 'Malicious]; DROP TABLE Users;--'
        # Returns: Malicious]]; DROP TABLE Users;--
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Name
  )

  # Escape ] as ]] to prevent breaking out of bracketed identifier context
  return $Name -replace '\]', ']]'
}

function Test-SchemaExcluded {
  <#
    .SYNOPSIS
        Checks if a script file belongs to an excluded schema.
    .DESCRIPTION
        Extracts schema from filename patterns like 'Schema.ObjectName.sql' or
        'Schema.ObjectName.type.sql' and checks against excluded schemas list.
        Only applies to schema-bound object folders (Tables, Views, Functions, etc.)
        to avoid false positives on users/roles/security objects.
    .PARAMETER ScriptPath
        Full path to the script file.
    .PARAMETER ExcludeSchemas
        Array of schema names to exclude.
    .OUTPUTS
        $true if script's schema is excluded, $false otherwise.
  #>
  param(
    [string]$ScriptPath,
    [string[]]$ExcludeSchemas
  )

  if (-not $ExcludeSchemas -or $ExcludeSchemas.Count -eq 0) {
    return $false
  }

  # Only apply schema filtering to folders containing schema-bound objects
  # This prevents false positives like user "cdc.user.sql" being treated as schema "cdc"
  # Note: Programmability has nested subfolders (02_Functions, 03_StoredProcedures, etc.)
  $schemaBoundFolders = @(
    'Tables',           # Matches 09_Tables_PrimaryKey, 10_Tables_ForeignKeys, etc.
    'Indexes',          # Matches 11_Indexes
    'Views',            # Matches 05_Views (nested under 14_Programmability)
    'Functions',        # Matches 02_Functions (nested under 14_Programmability)
    'StoredProcedures', # Matches 03_StoredProcedures (nested under 14_Programmability)
    'Triggers',         # Matches 04_Triggers (nested under 14_Programmability)
    'Synonyms',         # Matches 15_Synonyms
    'Sequences',        # Matches 04_Sequences
    'Data'              # Matches 21_Data
  )

  # Extract folder name from path (immediate parent)
  $parentFolder = Split-Path (Split-Path $ScriptPath -Parent) -Leaf

  # Check if this is a schema-bound folder
  # Use partial matching since folders have numeric prefixes (e.g., 09_Tables_PrimaryKey)
  $isSchemaBoundFolder = $false
  foreach ($folder in $schemaBoundFolders) {
    if ($parentFolder -match $folder) {
      $isSchemaBoundFolder = $true
      break
    }
  }

  if (-not $isSchemaBoundFolder) {
    return $false  # Not a schema-bound folder, don't filter
  }

  $fileName = Split-Path $ScriptPath -Leaf

  # Pattern 1: Schema.ObjectName.sql or Schema.ObjectName.type.sql
  # Examples: cdc.fn_cdc_get_all_changes.function.sql, dbo.MyTable.sql
  if ($fileName -match '^([^.]+)\.') {
    $schemaName = $matches[1]

    # Skip numeric prefixes from grouped files (e.g., 001_dbo.sql -> extract dbo)
    if ($schemaName -match '^\d{3}_(.+)$') {
      $schemaName = $matches[1]
    }

    if ($ExcludeSchemas -contains $schemaName) {
      return $true
    }
  }

  return $false
}

function Test-ScriptExcluded {
  <#
    .SYNOPSIS
        Checks if a script file should be excluded based on ExcludeObjectTypes settings.
    .DESCRIPTION
        Determines exclusion based on folder path and filename patterns.
        Supports granular user type exclusions (WindowsUsers, SqlUsers, etc.).
    .PARAMETER ScriptPath
        Full path to the script file.
    .PARAMETER ExcludeTypes
        Array of object types to exclude.
    .OUTPUTS
        $true if script should be excluded, $false otherwise.
  #>
  param(
    [string]$ScriptPath,
    [string[]]$ExcludeTypes
  )

  if (-not $ExcludeTypes -or $ExcludeTypes.Count -eq 0) {
    return $false
  }

  $fileName = Split-Path $ScriptPath -Leaf
  $relativePath = $ScriptPath

  # Build exclusion patterns based on ExcludeTypes
  foreach ($excludeType in $ExcludeTypes) {
    switch ($excludeType) {
      'FileGroups' {
        if ($relativePath -match '00_FileGroups') { return $true }
      }
      'DatabaseConfiguration' {
        if ($relativePath -match '02_DatabaseConfiguration') { return $true }
      }
      'Schemas' {
        if ($relativePath -match '03_Schemas') { return $true }
      }
      'Sequences' {
        if ($relativePath -match '04_Sequences') { return $true }
      }
      'PartitionFunctions' {
        if ($relativePath -match '05_PartitionFunctions') { return $true }
      }
      'PartitionSchemes' {
        if ($relativePath -match '06_PartitionSchemes') { return $true }
      }
      'Types' {
        if ($relativePath -match '07_Types') { return $true }
      }
      'XmlSchemaCollections' {
        if ($relativePath -match '08_XmlSchemaCollections') { return $true }
      }
      'Tables' {
        if ($relativePath -match '09_Tables|10_Tables') { return $true }
      }
      'ForeignKeys' {
        if ($relativePath -match '10_Tables.*ForeignKeys') { return $true }
      }
      'Indexes' {
        if ($relativePath -match '11_Indexes') { return $true }
      }
      'Defaults' {
        if ($relativePath -match '12_Defaults') { return $true }
      }
      'Rules' {
        if ($relativePath -match '13_Rules') { return $true }
      }
      'Programmability' {
        if ($relativePath -match '14_Programmability') { return $true }
      }
      'Views' {
        if ($relativePath -match '14_Programmability[\\/]05_Views') { return $true }
      }
      'Functions' {
        if ($relativePath -match '14_Programmability[\\/]02_Functions') { return $true }
      }
      'StoredProcedures' {
        if ($relativePath -match '14_Programmability[\\/]03_StoredProcedures') { return $true }
      }
      'Synonyms' {
        if ($relativePath -match '15_Synonyms') { return $true }
      }
      'SearchPropertyLists' {
        if ($relativePath -match '18_SearchPropertyLists') { return $true }
      }
      'PlanGuides' {
        if ($relativePath -match '19_PlanGuides') { return $true }
      }
      'DatabaseRoles' {
        # Exclude .role.sql files in 01_Security
        if ($relativePath -match '01_Security' -and $fileName -match '\.role\.sql$') { return $true }
      }
      'DatabaseUsers' {
        # Exclude ALL .user.sql files (umbrella exclusion)
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') { return $true }
      }
      'WindowsUsers' {
        # Exclude Windows domain user files based on file CONTENT (not filename pattern)
        # Detection patterns for Windows users:
        #   1. FOR LOGIN [DOMAIN\User] - explicit login mapping with backslash
        #   2. CREATE USER [DOMAIN\User] - implicit (username = login name, contains backslash)
        # Example filenames: "dbo.DOMAIN.TestUser.user.sql", "dbo.NT SERVICE.SQLSERVERAGENT.user.sql"
        # Windows principals: DOMAIN\User, NT SERVICE\name, NT AUTHORITY\SYSTEM, BUILTIN\Administrators
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content) {
            # Method 1: Check FOR LOGIN [name] for backslash
            if ($content -match 'FOR LOGIN\s*\[([^\]]+)\]') {
              $loginName = $matches[1]
              if ($loginName -match '\\') {
                return $true
              }
            }
            # Method 2: Check CREATE USER [name] for backslash (implicit Windows login)
            # This handles: CREATE USER [DOMAIN\User] WITH DEFAULT_SCHEMA=[dbo]
            if ($content -match 'CREATE USER\s*\[([^\]]+)\]') {
              $userName = $matches[1]
              # Windows users have backslash AND no "WITHOUT LOGIN" or "FROM EXTERNAL PROVIDER"
              if ($userName -match '\\' -and $content -notmatch 'WITHOUT LOGIN' -and $content -notmatch 'EXTERNAL PROVIDER') {
                return $true
              }
            }
          }
        }
      }
      'SqlUsers' {
        # Exclude SQL Server login mapped users based on file CONTENT
        # Detection: File contains "FOR LOGIN [username]" where login name has NO backslash
        #            and is NOT an external provider (Azure AD)
        # Also includes: "WITHOUT LOGIN" users (contained database users)
        # Example filenames: "dbo.AppUser.user.sql", "dbo.sa.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content) {
            # Check for explicit FOR LOGIN without backslash (SQL login)
            if ($content -match 'FOR LOGIN\s*\[([^\]]+)\]') {
              $loginName = $matches[1]
              # SQL logins: no backslash (not Windows), not external provider (not Azure AD)
              if ($loginName -notmatch '\\' -and $content -notmatch 'EXTERNAL PROVIDER') {
                return $true
              }
            }
            # WITHOUT LOGIN users are SQL type (contained database users)
            if ($content -match 'WITHOUT LOGIN') {
              return $true
            }
            # Implicit SQL login: CREATE USER [name] where name has no backslash
            # and no WITHOUT LOGIN, no EXTERNAL PROVIDER, no FOR LOGIN
            # This handles: CREATE USER [AppUser] WITH DEFAULT_SCHEMA=[dbo]
            if ($content -match 'CREATE USER\s*\[([^\]]+)\]') {
              $userName = $matches[1]
              if ($userName -notmatch '\\' -and $content -notmatch 'WITHOUT LOGIN' -and
                  $content -notmatch 'EXTERNAL PROVIDER' -and $content -notmatch 'FOR LOGIN') {
                return $true
              }
            }
          }
        }
      }
      'ExternalUsers' {
        # Exclude Azure AD / External provider users based on file CONTENT
        # Detection: File contains "EXTERNAL PROVIDER" or "FROM EXTERNAL PROVIDER"
        # Example filenames: "dbo.user@domain.com.user.sql", "dbo.AzureADGroup.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content -match 'EXTERNAL PROVIDER|FROM EXTERNAL PROVIDER') {
            return $true
          }
        }
      }
      'CertificateMappedUsers' {
        # Exclude certificate or asymmetric key mapped users based on file CONTENT
        # Detection: File contains "FOR CERTIFICATE" or "FOR ASYMMETRIC KEY"
        # Example filenames: "dbo.CertUser.user.sql", "dbo.KeyMappedUser.user.sql"
        if ($relativePath -match '01_Security' -and $fileName -match '\.user\.sql$') {
          $content = Get-Content $ScriptPath -Raw -ErrorAction SilentlyContinue
          if ($content -match 'FOR CERTIFICATE|FOR ASYMMETRIC KEY') {
            return $true
          }
        }
      }
      'SecurityPolicies' {
        if ($relativePath -match '20_SecurityPolicies') { return $true }
      }
      'Data' {
        if ($relativePath -match '21_Data') { return $true }
      }
    }
  }

  return $false
}

function Get-ScriptFiles {
  <#
    .SYNOPSIS
        Gets SQL script files in dependency order, filtered by import mode.
    #>
  param(
    [string]$Path,
    [switch]$IncludeData,
    [string]$Mode = 'Dev',
    $Config = @{}
  )

  # Get mode-specific settings
  # Support both simplified config (no import.mode structure) and full config (nested)
  $modeSettings = if ($Mode -eq 'Dev') {
    if ($Config.import -and $Config.import.developerMode) {
      # Full config format with nested mode settings
      $Config.import.developerMode
    }
    else {
      # Simplified config or no config - use Dev defaults
      @{
        fileGroupStrategy                = 'autoRemap'  # Default: auto-remap FileGroups
        includeConfigurations            = $false
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $false
        enableSecurityPolicies           = $false
      }
    }
  }
  else {
    # Prod mode
    if ($Config.import -and $Config.import.productionMode) {
      # Full config format with nested mode settings
      $Config.import.productionMode
    }
    else {
      # Simplified config or no config - use Prod defaults
      @{
        includeFileGroups                = $true
        includeConfigurations            = $true
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $true
        enableSecurityPolicies           = $true
      }
    }
  }

  # Build ordered directory list based on mode
  $orderedDirs = @()

  # FileGroups - handle based on strategy in Dev mode
  if ($Mode -eq 'Dev') {
    $fileGroupStrategy = if ($modeSettings.ContainsKey('fileGroupStrategy')) {
      $modeSettings.fileGroupStrategy
    }
    else {
      'autoRemap'  # Default strategy
    }

    if ($fileGroupStrategy -eq 'autoRemap') {
      # Check if source has FileGroups
      $sourceFileGroups = Join-Path $Path '00_FileGroups'
      if (Test-Path $sourceFileGroups) {
        $orderedDirs += '00_FileGroups'
        # Signal that we need auto-generate paths (handled later in main script)
      }
    }
    elseif ($fileGroupStrategy -eq 'removeToPrimary') {
      # Skip FileGroups entirely, transformations will handle references
    }
  }
  else {
    # Prod mode - also use fileGroupStrategy
    $prodStrategy = if ($modeSettings.ContainsKey('fileGroupStrategy')) {
      $modeSettings.fileGroupStrategy
    } else {
      'autoRemap'  # Default strategy
    }

    if ($prodStrategy -eq 'autoRemap') {
      $sourceFileGroups = Join-Path $Path '00_FileGroups'
      if (Test-Path $sourceFileGroups) {
        $orderedDirs += '00_FileGroups'
      }
    }
    # removeToPrimary: Skip FileGroups entirely
  }

  # Security - MUST come before schemas since schemas may have GRANT statements referencing roles/users
  $orderedDirs += '01_Security'

  # Database Configuration - skip in Dev mode unless explicitly enabled
  if ($modeSettings.includeConfigurations) {
    $orderedDirs += '02_DatabaseConfiguration'
  }

  # Core schema objects - always included
  $orderedDirs += @(
    '03_Schemas',
    '04_Sequences',
    '05_PartitionFunctions',
    '06_PartitionSchemes',
    '07_Types',
    '08_XmlSchemaCollections',
    '09_Tables_PrimaryKey',
    '10_Tables_ForeignKeys',
    '11_Indexes',
    '12_Defaults',
    '13_Rules',
    '14_Programmability',
    '15_Synonyms',
    '16_FullTextSearch'
  )

  # External Data - skip in Dev mode unless explicitly enabled
  if ($modeSettings.includeExternalData) {
    $orderedDirs += '17_ExternalData'
  }

  # Search Property Lists and Plan Guides - always included (harmless)
  $orderedDirs += @(
    '18_SearchPropertyLists',
    '19_PlanGuides'
  )

  # Security Policies - only in Prod mode
  if ($modeSettings.enableSecurityPolicies) {
    $orderedDirs += '20_SecurityPolicies'
  }

  # Data - only if requested
  Write-Verbose "Get-ScriptFiles: IncludeData parameter = $IncludeData"
  if ($IncludeData) {
    $orderedDirs += '21_Data'
    Write-Verbose "Added 21_Data to ordered directories"
  }
  else {
    Write-Verbose "Skipping 21_Data (IncludeData=$IncludeData)"
  }

  # Initialize subfolder paths array (used when filtering granular types like Views, Functions, StoredProcedures)
  $subfolderPaths = @()

  # Apply IncludeObjectTypes filter if specified (command-line parameter)
  if ($script:IncludeObjectTypesFilter -and $script:IncludeObjectTypesFilter.Count -gt 0) {
    Write-Verbose "Applying IncludeObjectTypes filter: $($script:IncludeObjectTypesFilter -join ', ')"

    # Map object type names to folder names (and subfolders for granular types)
    $folderMap = @{
      'FileGroups'            = '00_FileGroups'
      'DatabaseConfiguration' = '02_DatabaseConfiguration'
      'Schemas'               = '03_Schemas'
      'Sequences'             = '04_Sequences'
      'PartitionFunctions'    = '05_PartitionFunctions'
      'PartitionSchemes'      = '06_PartitionSchemes'
      'Types'                 = '07_Types'
      'XmlSchemaCollections'  = '08_XmlSchemaCollections'
      'Tables'                = @('09_Tables_PrimaryKey', '10_Tables_ForeignKeys')
      'ForeignKeys'           = '10_Tables_ForeignKeys'
      'Indexes'               = '11_Indexes'
      'Defaults'              = '12_Defaults'
      'Rules'                 = '13_Rules'
      'Programmability'       = '14_Programmability'
      'Views'                 = '14_Programmability\05_Views'  # Subfolder path
      'Functions'             = '14_Programmability\02_Functions'  # Subfolder path
      'StoredProcedures'      = '14_Programmability\03_StoredProcedures'  # Subfolder path
      'Synonyms'              = '15_Synonyms'
      'SearchPropertyLists'   = '18_SearchPropertyLists'
      'PlanGuides'            = '19_PlanGuides'
      'DatabaseRoles'         = '01_Security'
      'DatabaseUsers'         = '01_Security'
      'SecurityPolicies'      = '20_SecurityPolicies'
      'Data'                  = '21_Data'
    }

    $filteredDirs = @()
    # Always include Security if any security-related types are included
    $needsSecurity = ($script:IncludeObjectTypesFilter -contains 'DatabaseRoles') -or
    ($script:IncludeObjectTypesFilter -contains 'DatabaseUsers')

    foreach ($objType in $script:IncludeObjectTypesFilter) {
      if ($folderMap.ContainsKey($objType)) {
        $folders = $folderMap[$objType]
        if ($folders -is [array]) {
          $filteredDirs += $folders
        }
        else {
          $filteredDirs += $folders
        }
      }
    }

    # Remove duplicates and separate top-level folders from subfolders
    $filteredDirs = $filteredDirs | Select-Object -Unique
    $topLevelDirs = @()
    $subfolderPaths = @()

    foreach ($dir in $filteredDirs) {
      if ($dir -match '\\') {
        # This is a subfolder path (e.g., "14_Programmability\05_Views")
        $subfolderPaths += $dir
        $topLevel = $dir.Split('\')[0]
        if ($topLevel -notin $topLevelDirs) {
          $topLevelDirs += $topLevel
        }
      }
      else {
        # This is a top-level folder
        $topLevelDirs += $dir
      }
    }

    # Also include 01_Security if DatabaseRoles or DatabaseUsers are included
    if ($needsSecurity -and '01_Security' -notin $topLevelDirs) {
      $topLevelDirs += '01_Security'
    }

    # Filter orderedDirs to only include top-level folders that are needed
    $orderedDirs = $orderedDirs | Where-Object { $_ -in $topLevelDirs }
    Write-Verbose "Filtered top-level folders: $($orderedDirs -join ', ')"
    if ($subfolderPaths.Count -gt 0) {
      Write-Verbose "Subfolder filters: $($subfolderPaths -join ', ')"
    }
  }

  $scripts = @()
  $skippedFolders = @()

  foreach ($dir in $orderedDirs) {
    $fullPath = Join-Path $Path $dir
    if (Test-Path $fullPath) {
      # Special handling for SecurityPolicies folder - may need to skip in Dev mode
      if ($dir -eq '20_SecurityPolicies' -and -not $modeSettings.enableSecurityPolicies) {
        Write-Output "  [INFO] Skipping Row-Level Security policies (disabled in $Mode mode)"
        continue
      }

      # Check if we have subfolder filters for this directory
      $relevantSubfolders = @($subfolderPaths | Where-Object { $_.StartsWith("$dir\") })

      if ($relevantSubfolders.Count -gt 0) {
        # Only get files from specific subfolders
        foreach ($subfolderPath in $relevantSubfolders) {
          $subfolderFullPath = Join-Path $Path $subfolderPath
          if (Test-Path $subfolderFullPath) {
            $scripts += @(Get-ChildItem -Path $subfolderFullPath -Filter '*.sql' -Recurse |
              Sort-Object FullName)
          }
        }
      }
      else {
        # No subfolder filter - get all SQL files recursively from this folder
        $scripts += @(Get-ChildItem -Path $fullPath -Filter '*.sql' -Recurse |
          Sort-Object FullName)
      }
    }
  }

  # Apply ExcludeObjectTypes filter if specified (command-line parameter)
  if ($script:ExcludeObjectTypesFilter -and $script:ExcludeObjectTypesFilter.Count -gt 0) {
    Write-Verbose "Applying ExcludeObjectTypes filter: $($script:ExcludeObjectTypesFilter -join ', ')"
    $originalCount = $scripts.Count
    $scripts = @($scripts | Where-Object {
        -not (Test-ScriptExcluded -ScriptPath $_.FullName -ExcludeTypes $script:ExcludeObjectTypesFilter)
      })
    $excludedCount = $originalCount - $scripts.Count
    if ($excludedCount -gt 0) {
      Write-Output "  [INFO] Excluded $excludedCount script(s) based on ExcludeObjectTypes filter"
    }
  }

  # Apply ExcludeSchemas filter if specified (command-line parameter)
  if ($script:ExcludeSchemasFilter -and $script:ExcludeSchemasFilter.Count -gt 0) {
    Write-Verbose "Applying ExcludeSchemas filter: $($script:ExcludeSchemasFilter -join ', ')"
    $originalCount = $scripts.Count
    $scripts = @($scripts | Where-Object {
        -not (Test-SchemaExcluded -ScriptPath $_.FullName -ExcludeSchemas $script:ExcludeSchemasFilter)
      })
    $excludedCount = $originalCount - $scripts.Count
    if ($excludedCount -gt 0) {
      Write-Output "  [INFO] Excluded $excludedCount script(s) based on ExcludeSchemas filter"
    }
  }

  # Track skipped folders for reporting
  $allPossibleDirs = @('00_FileGroups', '02_DatabaseConfiguration', '17_ExternalData', '20_SecurityPolicies', '21_Data')
  foreach ($dir in $allPossibleDirs) {
    if ($dir -notin $orderedDirs) {
      $fullPath = Join-Path $Path $dir
      if (Test-Path $fullPath) {
        $skippedFolders += $dir
      }
    }
  }

  # Return both scripts and skipped folders info
  return @{
    Scripts         = $scripts
    SkippedFolders  = $skippedFolders
    IncludedFolders = $orderedDirs
  }
}

function Import-YamlConfig {
  <#
    .SYNOPSIS
        Loads and parses YAML configuration file.
    #>
  param([string]$ConfigFilePath)

  if (-not (Test-Path $ConfigFilePath)) {
    throw "Configuration file not found: $ConfigFilePath"
  }

  Write-Host "[INFO] Loading configuration from: $ConfigFilePath"

  try {
    # Check for PowerShell-Yaml module
    if (-not (Get-Module -ListAvailable -Name powershell-yaml)) {
      Write-Host ""
      Write-Host "[ERROR] PowerShell-Yaml module not found" -ForegroundColor Red
      Write-Host "[INFO] Install with: Install-Module powershell-yaml -Scope CurrentUser" -ForegroundColor Yellow
      Write-Host ""
      throw "PowerShell-Yaml module is required to parse YAML configuration files"
    }

    Import-Module powershell-yaml -ErrorAction Stop
    $yamlContent = Get-Content $ConfigFilePath -Raw
    $parsedYaml = ConvertFrom-Yaml $yamlContent

    # ConvertFrom-Yaml may return an array if there are multiple documents
    # Ensure we return a single hashtable
    if ($parsedYaml -is [System.Array]) {
      if ($parsedYaml.Count -eq 1) {
        $config = $parsedYaml[0]
      }
      else {
        throw "Configuration file contains multiple YAML documents. Only single document configs are supported."
      }
    }
    else {
      $config = $parsedYaml
    }

    # Ensure we have a hashtable (OrderedDictionary is fine too)
    if (-not ($config -is [System.Collections.IDictionary])) {
      throw "Configuration file did not parse to a valid hashtable/dictionary structure. Type: $($config.GetType().FullName)"
    }

    # NOTE: Do NOT add default import structure here
    # Let Get-ScriptFiles and Show-ImportConfiguration handle defaults
    # This allows simplified configs (with importMode at root) to work

    Write-Host "[SUCCESS] Configuration loaded successfully" -ForegroundColor Green
    return $config

  }
  catch {
    Write-Host "[ERROR] Failed to parse configuration file: $_" -ForegroundColor Red
    throw
  }
}

function Show-ImportConfiguration {
  <#
    .SYNOPSIS
        Displays the active import configuration at script start.
    #>
  param(
    [string]$ServerName,
    [string]$DatabaseName,
    [string]$SourceDirectory,
    [string]$Mode,
    $Config = @{},
    [bool]$DataImport = $false,
    [bool]$DatabaseCreation = $false,
    [string]$ConfigSource = "None (using defaults)"
  )

  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "Import-SqlServerSchema" -ForegroundColor Cyan
  Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "Target Server: " -NoNewline -ForegroundColor Gray
  Write-Host $ServerName -ForegroundColor White
  Write-Host "Target Database: " -NoNewline -ForegroundColor Gray
  Write-Host $DatabaseName -ForegroundColor White
  Write-Host "Source: " -NoNewline -ForegroundColor Gray
  Write-Host $SourceDirectory -ForegroundColor White
  Write-Host ""
  Write-Host "CONFIGURATION" -ForegroundColor Yellow
  Write-Host "-------------" -ForegroundColor Yellow
  Write-Host "Config File: " -NoNewline -ForegroundColor Gray
  Write-Host $ConfigSource -ForegroundColor White
  Write-Host "Import Mode: " -NoNewline -ForegroundColor Gray
  Write-Host $Mode -ForegroundColor $(if ($Mode -eq 'Prod') { 'Red' } else { 'Green' })
  Write-Host "Create Database: " -NoNewline -ForegroundColor Gray
  Write-Host $(if ($DatabaseCreation) { "Yes" } else { "No" }) -ForegroundColor White
  Write-Host "Include Data: " -NoNewline -ForegroundColor Gray
  Write-Host $(if ($DataImport) { "Yes" } else { "No" }) -ForegroundColor White

  # Display Include/Exclude object type filters if active
  if ($script:IncludeObjectTypesFilter -and $script:IncludeObjectTypesFilter.Count -gt 0) {
    Write-Host "Include Types: " -NoNewline -ForegroundColor Gray
    Write-Host ($script:IncludeObjectTypesFilter -join ', ') -ForegroundColor Cyan
  }
  if ($script:ExcludeObjectTypesFilter -and $script:ExcludeObjectTypesFilter.Count -gt 0) {
    Write-Host "Exclude Types: " -NoNewline -ForegroundColor Gray
    Write-Host ($script:ExcludeObjectTypesFilter -join ', ') -ForegroundColor Yellow
  }

  Write-Host ""
  Write-Host "IMPORT STRATEGY ($Mode Mode)" -ForegroundColor Yellow
  Write-Host "$(('-' * (17 + $Mode.Length)))" -ForegroundColor Yellow

  # Get mode-specific settings
  # Support both simplified config (no import.mode structure) and full config (nested)
  $modeSettings = if ($Mode -eq 'Dev') {
    if ($Config.import -and $Config.import.developerMode) {
      # Full config format with nested mode settings
      $Config.import.developerMode
    }
    else {
      # Simplified config or no config - use Dev defaults
      @{
        fileGroupStrategy                = 'autoRemap'  # Default: auto-remap FileGroups
        includeConfigurations            = $false
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $false
        enableSecurityPolicies           = $false
      }
    }
  }
  else {
    # Prod mode
    if ($Config.import -and $Config.import.productionMode) {
      # Full config format with nested mode settings
      $Config.import.productionMode
    }
    else {
      # Simplified config or no config - use Prod defaults
      @{
        fileGroupStrategy                = 'autoRemap'  # Default: auto-remap FileGroups
        includeConfigurations            = $true
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $true
        enableSecurityPolicies           = $true
      }
    }
  }

  # Display mode-specific settings - determine from fileGroupStrategy
  $displayStrategy = if ($modeSettings.ContainsKey('fileGroupStrategy')) { $modeSettings.fileGroupStrategy } else { 'autoRemap' }
  if ($displayStrategy -eq 'autoRemap') {
    Write-Host "[ENABLED] FileGroups" -ForegroundColor Green
  }
  else {
    Write-Host "[SKIPPED] FileGroups (environment-specific)" -ForegroundColor Yellow
  }

  if ($modeSettings.includeConfigurations) {
    Write-Host "[ENABLED] Database Scoped Configurations" -ForegroundColor Green
  }
  else {
    Write-Host "[SKIPPED] Database Scoped Configurations (hardware-specific)" -ForegroundColor Yellow
  }

  if ($modeSettings.includeDatabaseScopedCredentials) {
    Write-Host "[ENABLED] Database Scoped Credentials" -ForegroundColor Green
  }
  else {
    Write-Host "[SKIPPED] Database Scoped Credentials (always - secrets required)" -ForegroundColor Gray
  }

  if ($modeSettings.includeExternalData) {
    Write-Host "[ENABLED] External Data Sources" -ForegroundColor Green
  }
  else {
    Write-Host "[SKIPPED] External Data Sources (environment-specific)" -ForegroundColor Yellow
  }

  if ($modeSettings.enableSecurityPolicies) {
    Write-Host "[ENABLED] Row-Level Security Policies" -ForegroundColor Green
  }
  else {
    Write-Host "[DISABLED] Row-Level Security Policies (dev convenience)" -ForegroundColor Yellow
  }

  # Check stripFilestream from config or command-line parameter
  $displayStripFilestream = $script:StripFilestreamEnabled
  if (-not $displayStripFilestream -and $modeSettings.ContainsKey('stripFilestream') -and $modeSettings.stripFilestream -eq $true) {
    $displayStripFilestream = $true
  }
  if ($displayStripFilestream) {
    Write-Host "[ENABLED] Strip FILESTREAM (Linux/container compatibility)" -ForegroundColor Magenta
  }

  # Check stripAlwaysEncrypted from config or command-line parameter
  $displayStripAlwaysEncrypted = $script:StripAlwaysEncryptedEnabled
  if (-not $displayStripAlwaysEncrypted -and $modeSettings.ContainsKey('stripAlwaysEncrypted') -and $modeSettings.stripAlwaysEncrypted -eq $true) {
    $displayStripAlwaysEncrypted = $true
  }
  if ($displayStripAlwaysEncrypted) {
    Write-Host "[ENABLED] Strip Always Encrypted (no external key store required)" -ForegroundColor Magenta
  }

  Write-Host ""
  Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
  Write-Host "Starting import..." -ForegroundColor Cyan
  Write-Host ""
}

#endregion

#region Main Script

try {
  # Start overall timing if collecting metrics (CLI switch, config applied later)
  $script:CollectMetrics = $CollectMetrics.IsPresent
  if ($script:CollectMetrics) {
    $script:ImportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $script:InitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  }

  # Load configuration if provided
  $config = @{
    import = @{
      defaultMode    = 'Dev'
      developerMode  = @{
        fileGroupStrategy                = 'autoRemap'
        includeConfigurations            = $false
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $false
        enableSecurityPolicies           = $false
      }
      productionMode = @{
        fileGroupStrategy                = 'autoRemap'
        includeConfigurations            = $true
        includeDatabaseScopedCredentials = $false
        includeExternalData              = $true
        enableSecurityPolicies           = $true
      }
    }
  }
  $configSource = "None (using defaults)"

  if ($ConfigFile) {
    if (Test-Path $ConfigFile) {
      $config = Import-YamlConfig -ConfigFilePath $ConfigFile
      $configSource = $ConfigFile

      # Support both simplified config (importMode at root) and full config (import.defaultMode nested)
      $configImportMode = if ($config.importMode) { $config.importMode } else { $config.import.defaultMode }

      # Override ImportMode from config ONLY if not explicitly set on command line
      # Command-line parameters always take precedence over config file
      if ($configImportMode -and -not $PSBoundParameters.ContainsKey('ImportMode')) {
        $ImportMode = $configImportMode
        Write-Output "[INFO] Import mode set from config file: $ImportMode"
      }

      # Override IncludeData from config ONLY if not explicitly set on command line
      # Support both simplified config (includeData at root) and full config (nested mode settings)
      # Use safe property access for strict mode compatibility
      $configIncludeData = if ($config -is [hashtable]) { $config['includeData'] } elseif ($config.PSObject.Properties.Name -contains 'includeData') { $config.includeData } else { $null }
      Write-Verbose "Config includeData value: $configIncludeData, Parameter IncludeData: $IncludeData"
      if (-not $PSBoundParameters.ContainsKey('IncludeData')) {
        # Check root-level includeData first
        if ($configIncludeData) {
          $IncludeData = $configIncludeData
          Write-Output "[INFO] Data import enabled from config file"
        }
        # Then check mode-specific settings
        elseif ($config.import) {
          $modeSettings = if ($ImportMode -eq 'Dev') { $config.import.developerMode } else { $config.import.productionMode }
          $modeIncludeData = if ($modeSettings -and $modeSettings -is [hashtable]) { $modeSettings['includeData'] } elseif ($modeSettings -and $modeSettings.PSObject.Properties.Name -contains 'includeData') { $modeSettings.includeData } else { $null }
          if ($modeIncludeData) {
            $IncludeData = $modeIncludeData
            Write-Output "[INFO] Data import enabled from config file ($ImportMode mode)"
          }
        }
      }

      # Override CreateDatabase from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('CreateDatabase')) {
        if ($config.import.createDatabase) {
          $CreateDatabase = $config.import.createDatabase
          Write-Verbose "[INFO] CreateDatabase set from config file: $CreateDatabase"
        }
      }

      # Override Force from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('Force')) {
        if ($config.import.force) {
          $Force = $config.import.force
          Write-Verbose "[INFO] Force set from config file: $Force"
        }
      }

      # Override ContinueOnError from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('ContinueOnError')) {
        if ($config.import.continueOnError) {
          $ContinueOnError = $config.import.continueOnError
          $ErrorActionPreference = 'Continue'
          Write-Verbose "[INFO] ContinueOnError set from config file: $ContinueOnError"
        }
      }

      # Override ShowSQL from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('ShowSQL')) {
        if ($config.import.showSql) {
          $ShowSQL = $config.import.showSql
          Write-Verbose "[INFO] ShowSQL set from config file: $ShowSQL"
        }
      }

      # Override CollectMetrics from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('CollectMetrics')) {
        if ($config.collectMetrics) {
          $script:CollectMetrics = $config.collectMetrics
          # Start metrics if enabled by config (if not already started)
          if ($script:CollectMetrics -and -not $script:ImportStopwatch) {
            $script:ImportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
            $script:InitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
          }
        }
      }

      # Override IncludeObjectTypes from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('IncludeObjectTypes')) {
        if ($config.import.includeObjectTypes -and $config.import.includeObjectTypes.Count -gt 0) {
          $script:IncludeObjectTypesFilter = $config.import.includeObjectTypes
          Write-Verbose "[INFO] IncludeObjectTypes set from config file: $($config.import.includeObjectTypes -join ', ')"
        }
      }

      # Override ExcludeObjectTypes from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('ExcludeObjectTypes')) {
        if ($config.import.excludeObjectTypes -and $config.import.excludeObjectTypes.Count -gt 0) {
          $script:ExcludeObjectTypesFilter = $config.import.excludeObjectTypes
          Write-Verbose "[INFO] ExcludeObjectTypes set from config file: $($config.import.excludeObjectTypes -join ', ')"
        }
      }

      # Override ExcludeSchemas from config ONLY if not explicitly set on command line
      if (-not $PSBoundParameters.ContainsKey('ExcludeSchemas')) {
        if ($config.import.excludeSchemas -and $config.import.excludeSchemas.Count -gt 0) {
          $script:ExcludeSchemasFilter = $config.import.excludeSchemas
          Write-Verbose "[INFO] ExcludeSchemas set from config file: $($config.import.excludeSchemas -join ', ')"
        }
      }
    }
    else {
      Write-Warning "Config file not found: $ConfigFile"
      Write-Warning "Continuing with default settings..."
    }
  }

  # Resolve credentials from environment variables (if specified)
  # Precedence: CLI -Credential/-Server > *FromEnv CLI params > config connection: section > defaults
  $envResolved = Resolve-EnvCredential `
    -ServerParam $Server `
    -CredentialParam $Credential `
    -ServerFromEnvParam $ServerFromEnv `
    -UsernameFromEnvParam $UsernameFromEnv `
    -PasswordFromEnvParam $PasswordFromEnv `
    -TrustServerCertificateParam $TrustServerCertificate.IsPresent `
    -Config $config `
    -BoundParameters $PSBoundParameters
  $Server = $envResolved.Server
  $Credential = $envResolved.Credential
  $script:TrustServerCertificateEnabled = $envResolved.TrustServerCertificate

  # Validate that Server was resolved from at least one source
  if ([string]::IsNullOrWhiteSpace($Server)) {
    throw "Server is required. Provide it via -Server, -ServerFromEnv, or config file connection.serverFromEnv."
  }

  # Handle -ShowRequiredSecrets mode (display and exit without importing)
  if ($ShowRequiredSecrets) {
    Write-Output ""
    Write-Output "Scanning export for encryption objects..."
    $encryptionObjects = Get-RequiredEncryptionSecrets -SourcePath $SourcePath

    if ($encryptionObjects) {
      Show-EncryptionSecretsTemplate -SourcePath $SourcePath -EncryptionObjects $encryptionObjects
    }
    else {
      Write-Host ""
      Write-Host "No encryption objects requiring passwords found in this export." -ForegroundColor Green
      Write-Host ""
      Write-Host "This export does not contain:" -ForegroundColor Gray
      Write-Host "  - Database Master Key"
      Write-Host "  - Symmetric Keys"
      Write-Host "  - Certificates"
      Write-Host "  - Asymmetric Keys"
      Write-Host "  - Application Roles"
      Write-Host ""
      Write-Host "No encryptionSecrets configuration is needed for import." -ForegroundColor Green
      Write-Host ""
    }
    exit 0
  }

  # Apply timeout settings from config or use defaults
  # Parameters override config values (if non-zero)
  $effectiveConnectionTimeout = if ($ConnectionTimeout -gt 0) {
    $ConnectionTimeout
  }
  elseif ($config -and $config.ContainsKey('connectionTimeout')) {
    $config.connectionTimeout
  }
  else {
    30
  }

  $effectiveCommandTimeout = if ($CommandTimeout -gt 0) {
    $CommandTimeout
  }
  elseif ($config -and $config.ContainsKey('commandTimeout')) {
    $config.commandTimeout
  }
  else {
    300
  }

  $effectiveMaxRetries = if ($MaxRetries -gt 0) {
    $MaxRetries
  }
  elseif ($config -and $config.ContainsKey('maxRetries')) {
    $config.maxRetries
  }
  else {
    3
  }

  $effectiveRetryDelay = if ($RetryDelaySeconds -gt 0) {
    $RetryDelaySeconds
  }
  elseif ($config -and $config.ContainsKey('retryDelaySeconds')) {
    $config.retryDelaySeconds
  }
  else {
    2
  }

  Write-Verbose "Using connection timeout: $effectiveConnectionTimeout seconds"
  Write-Verbose "Using command timeout: $effectiveCommandTimeout seconds"
  Write-Verbose "Using max retries: $effectiveMaxRetries attempts"
  Write-Verbose "Using retry delay: $effectiveRetryDelay seconds"

  # Display configuration
  Show-ImportConfiguration `
    -ServerName $Server `
    -DatabaseName $Database `
    -SourceDirectory $SourcePath `
    -Mode $ImportMode `
    -Config $config `
    -DataImport $IncludeData `
    -DatabaseCreation $CreateDatabase `
    -ConfigSource $configSource

  # Initialize log file
  $script:LogFile = Join-Path $SourcePath 'import-log.txt'
  Write-Log "Import started" -Severity INFO
  Write-Log "Server: $Server" -Severity INFO
  Write-Log "Database: $Database" -Severity INFO
  Write-Log "Source: $SourcePath" -Severity INFO
  Write-Log "Import mode: $ImportMode" -Severity INFO
  Write-Log "Configuration source: $configSource" -Severity INFO

  # Validate dependencies
  $execMethod = Test-Dependencies
  Write-Output ''

  # End initialization timing, start preliminary checks timing
  if ($script:CollectMetrics) {
    $script:InitStopwatch.Stop()
    $script:Metrics.initializationSeconds = $script:InitStopwatch.Elapsed.TotalSeconds
    $script:PrelimStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[TIMING] Preliminary checks starting..."
  }

  # Create shared connection for preliminary checks and script execution
  # This eliminates connection overhead from multiple check functions
  # Note: Connect to 'master' first if -CreateDatabase is used (target DB might not exist yet)
  if ($script:CollectMetrics) {
    $script:ConnectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    Write-Verbose "[TIMING] Creating shared connection..."
  }
  try {
    # Connect to master first for preliminary checks - reconnect to target DB later if needed
    $initialDb = if ($CreateDatabase) { 'master' } else { $Database }
    $script:SharedConnection = New-SqlServerConnection -ServerName $Server -DatabaseName $initialDb -Cred $Credential -Config $config -Timeout $effectiveCommandTimeout
  }
  catch {
    Write-Error "[ERROR] Failed to create connection: $_"
    Write-Log "Failed to create connection to $Server" -Severity ERROR
    exit 1
  }
  if ($script:CollectMetrics) {
    $script:ConnectionStopwatch.Stop()
    $script:Metrics.connectionTimeSeconds = $script:ConnectionStopwatch.Elapsed.TotalSeconds
    Write-Verbose "[TIMING] Shared connection created in $([math]::Round($script:ConnectionStopwatch.Elapsed.TotalSeconds, 3))s"
  }

  # Test connection to server (reuse shared connection)
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Starting Test-DatabaseConnection..." }
  $testConnSw = [System.Diagnostics.Stopwatch]::StartNew()
  if (-not (Test-DatabaseConnection -ServerName $Server -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection)) {
    Write-Log "Connection test failed to $Server" -Severity ERROR
    exit 1
  }
  $testConnSw.Stop()
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Test-DatabaseConnection completed in $([math]::Round($testConnSw.Elapsed.TotalSeconds, 3))s" }
  Write-Log "Connection test successful to $Server" -Severity INFO
  Write-Output ''

  # Check if database exists (reuse shared connection)
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Starting Test-DatabaseExists..." }
  $testDbSw = [System.Diagnostics.Stopwatch]::StartNew()
  $dbExists = Test-DatabaseExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection
  $testDbSw.Stop()
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Test-DatabaseExists completed in $([math]::Round($testDbSw.Elapsed.TotalSeconds, 3))s" }

  if (-not $dbExists) {
    if ($CreateDatabase) {
      if (-not (New-Database -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout)) {
        exit 1
      }
      # Reconnect shared connection to the new database
      Write-Verbose "[TIMING] Reconnecting to target database..."
      $script:SharedConnection.ConnectionContext.Disconnect()
      $script:SharedConnection = New-SqlServerConnection -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveCommandTimeout
    }
    else {
      Write-Error "Database '$Database' does not exist. Use -CreateDatabase to create it."
      exit 1
    }
  }
  else {
    Write-Output "[SUCCESS] Target database exists: $Database"
    # If we connected to master initially (CreateDatabase flag), reconnect to target database
    if ($CreateDatabase) {
      Write-Verbose "[TIMING] Reconnecting to target database..."
      $script:SharedConnection.ConnectionContext.Disconnect()
      $script:SharedConnection = New-SqlServerConnection -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveCommandTimeout
    }
  }
  Write-Output ''

  # Check for existing schema (reuse shared connection)
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Starting Test-SchemaExists..." }
  $testSchemaSw = [System.Diagnostics.Stopwatch]::StartNew()
  if (Test-SchemaExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection) {
    if (-not $Force) {
      Write-Output "[INFO] Database $Database already contains schema objects."
      Write-Output "Use -Force to proceed with redeployment."
      exit 0
    }
    Write-Output '[INFO] Proceeding with redeployment due to -Force flag'
  }
  $testSchemaSw.Stop()
  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Test-SchemaExists completed in $([math]::Round($testSchemaSw.Elapsed.TotalSeconds, 3))s" }
  Write-Output ''

  if ($script:CollectMetrics) { Write-Verbose "[TIMING] Preliminary checks total so far: $([math]::Round($script:PrelimStopwatch.Elapsed.TotalSeconds, 3))s" }

  # End preliminary checks timing, start script collection timing
  if ($script:CollectMetrics) {
    $script:PrelimStopwatch.Stop()
    $script:Metrics.preliminaryChecksSeconds = $script:PrelimStopwatch.Elapsed.TotalSeconds
    $script:ScriptCollectStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  }

  # Get scripts in order
  Write-Output "Collecting scripts from: $(Split-Path -Leaf $SourcePath)"
  $scriptInfo = Get-ScriptFiles -Path $SourcePath -IncludeData:$IncludeData -Mode $ImportMode -Config $config
  $scripts = $scriptInfo.Scripts
  $skippedFolders = $scriptInfo.SkippedFolders
  $includedFolders = $scriptInfo.IncludedFolders

  if ($scripts.Count -eq 0) {
    Write-Error "No SQL scripts found in $SourcePath"
    exit 1
  }

  Write-Output "Found $($scripts.Count) script(s)"

  # Detect target server OS for path separator (reuse shared connection)
  $targetOS = Get-TargetServerOS -ServerName $Server -Cred $Credential -Config $config -Connection $script:SharedConnection
  $pathSeparator = if ($targetOS -eq 'Linux') { '/' } else { '\' }
  Write-Verbose "Using path separator for $targetOS`: $pathSeparator"

  # End script collection timing
  if ($script:CollectMetrics) {
    $script:ScriptCollectStopwatch.Stop()
    $script:Metrics.scriptCollectionSeconds = $script:ScriptCollectStopwatch.Elapsed.TotalSeconds
  }

  # Build SQLCMD variables from config (for FileGroup path mappings, etc.)
  $sqlCmdVars = @{}

  # Read export metadata for original FileGroup values
  $exportMetadata = Read-ExportMetadata -SourcePath $SourcePath

  # Get FileGroup file size defaults from config (if specified)
  # Use safe property access patterns for PowerShell 7.5+ compatibility
  $fgSizeDefaults = $null
  if ($config) {
    # Check if config is a hashtable or PSCustomObject and access property safely
    $rootFgDefaults = if ($config -is [hashtable]) { $config['fileGroupFileSizeDefaults'] } elseif ($config.PSObject.Properties.Name -contains 'fileGroupFileSizeDefaults') { $config.fileGroupFileSizeDefaults } else { $null }
    if ($rootFgDefaults) {
      $fgSizeDefaults = $rootFgDefaults
    }
    elseif ($config.import) {
      $modeConfigForSize = if ($ImportMode -eq 'Prod') { $config.import.productionMode } else { $config.import.developerMode }
      if ($modeConfigForSize) {
        # Safe property access for mode config (may be hashtable from defaults or PSCustomObject from YAML)
        $modeFgDefaults = if ($modeConfigForSize -is [hashtable]) { $modeConfigForSize['fileGroupFileSizeDefaults'] } elseif ($modeConfigForSize.PSObject.Properties.Name -contains 'fileGroupFileSizeDefaults') { $modeConfigForSize.fileGroupFileSizeDefaults } else { $null }
        if ($modeFgDefaults) {
          $fgSizeDefaults = $modeFgDefaults
        }
      }
    }
  }

  # Validate file group file size defaults early to provide clear errors for invalid configuration values
  if ($fgSizeDefaults) {
    [int]$parsedSizeKB = 0
    [int]$parsedFileGrowthKB = 0
    [int]$minFileSizeKB = 64
    [int]$maxFileSizeKB = 1073741824

    if ($fgSizeDefaults.sizeKB -ne $null) {
      if (-not [int]::TryParse($fgSizeDefaults.sizeKB.ToString(), [ref]$parsedSizeKB)) {
        Write-Host "[ERROR] Invalid configuration value for fileGroupFileSizeDefaults.sizeKB: '$($fgSizeDefaults.sizeKB)'. Expected an integer value in kilobytes between $minFileSizeKB and $maxFileSizeKB." -ForegroundColor Red
        throw "Invalid configuration value for fileGroupFileSizeDefaults.sizeKB."
      }
      elseif ($parsedSizeKB -lt $minFileSizeKB -or $parsedSizeKB -gt $maxFileSizeKB) {
        Write-Host "[ERROR] Configuration value for fileGroupFileSizeDefaults.sizeKB ($parsedSizeKB) is out of range. Allowed range is $minFileSizeKB KB to $maxFileSizeKB KB." -ForegroundColor Red
        throw "Out-of-range configuration value for fileGroupFileSizeDefaults.sizeKB."
      }
    }

    if ($fgSizeDefaults.fileGrowthKB -ne $null) {
      if (-not [long]::TryParse($fgSizeDefaults.fileGrowthKB.ToString(), [ref]$parsedFileGrowthKB)) {
        Write-Host "[ERROR] Invalid configuration value for fileGroupFileSizeDefaults.fileGrowthKB: '$($fgSizeDefaults.fileGrowthKB)'. Expected an integer value in kilobytes between $minFileSizeKB and $maxFileSizeKB." -ForegroundColor Red
        throw "Invalid configuration value for fileGroupFileSizeDefaults.fileGrowthKB."
      }
      elseif ($parsedFileGrowthKB -lt $minFileSizeKB -or $parsedFileGrowthKB -gt $maxFileSizeKB) {
        Write-Host "[ERROR] Configuration value for fileGroupFileSizeDefaults.fileGrowthKB ($parsedFileGrowthKB) is out of range. Allowed range is $minFileSizeKB KB to $maxFileSizeKB KB." -ForegroundColor Red
        throw "Out-of-range configuration value for fileGroupFileSizeDefaults.fileGrowthKB."
      }
    }

    Write-Output "[INFO] FileGroup file size defaults configured:"
    if ($fgSizeDefaults.sizeKB -ne $null) {
      Write-Output "  - SIZE = $($fgSizeDefaults.sizeKB)KB"
    }
    if ($fgSizeDefaults.fileGrowthKB -ne $null) {
      Write-Output "  - FILEGROWTH = $($fgSizeDefaults.fileGrowthKB)KB"
    }
  }
  elseif ($ImportMode -eq 'Dev') {
    # Apply safe defaults in Dev mode if no explicit configuration provided
    # This prevents large allocations from failing on developer systems with limited disk space
    $fgSizeDefaults = @{
      sizeKB       = 1024    # 1 MB initial size (safe default for dev)
      fileGrowthKB = 65536   # 64 MB growth (reasonable default)
    }
    Write-Output "[INFO] Using Dev mode safe defaults for FileGroup file sizes:"
    Write-Output "  - SIZE = $($fgSizeDefaults.sizeKB)KB (1 MB)"
    Write-Output "  - FILEGROWTH = $($fgSizeDefaults.fileGrowthKB)KB (64 MB)"
  }

  if ($config) {
    # Support both simplified config (fileGroupPathMapping at root) and full config (nested)
    # Use Get-SafeProperty to handle hashtable/PSCustomObject differences in PowerShell 7.5+
    $modeConfig = $null
    $rootPathMapping = Get-SafeProperty -Object $config -PropertyName 'fileGroupPathMapping'
    if ($rootPathMapping) {
      # Simplified config format (root-level fileGroupPathMapping)
      $modeConfig = $config
    }
    elseif ($config.import) {
      # Full config format (nested under import.productionMode or import.developerMode)
      $modeConfig = if ($ImportMode -eq 'Prod') { $config.import.productionMode } else { $config.import.developerMode }
    }

    $modePathMapping = Get-SafeProperty -Object $modeConfig -PropertyName 'fileGroupPathMapping'
    if ($modeConfig -and $modePathMapping) {
      # SECURITY: Sanitize database name for use in filesystem paths
      $sanitizedDbName = $Database -replace '[^a-zA-Z0-9_-]', '_'

      # First pass: read FileGroups SQL to extract file names
      $fileGroupScript = Join-Path $SourcePath '00_FileGroups' '001_FileGroups.sql'
      $fileGroupFiles = @{}  # Map: FileGroup -> [list of file names]

      if (Test-Path $fileGroupScript) {
        # Parse FileGroup names and file names from comments
        $currentFG = $null
        foreach ($line in (Get-Content $fileGroupScript)) {
          if ($line -match '-- FileGroup: (.+)') {
            $fgName = $matches[1].Trim()

            # SECURITY: Sanitize FileGroup name
            if ($fgName -notmatch '^[a-zA-Z0-9_-]+$') {
              Write-Warning "[WARNING] FileGroup name '$fgName' contains unsafe characters. Skipping."
              $currentFG = $null
              continue
            }

            $currentFG = $fgName
            $fileGroupFiles[$currentFG] = @()
          }
          elseif ($line -match '-- File: (.+)' -and $currentFG) {
            $fileName = $matches[1].Trim()

            # SECURITY: Sanitize filename
            if ($fileName -notmatch '^[a-zA-Z0-9_.-]+$') {
              Write-Warning "[WARNING] FileGroup file name '$fileName' contains unsafe characters. Skipping."
              continue
            }

            $fileGroupFiles[$currentFG] += $fileName
          }
        }
      }

      # Second pass: build SQLCMD variables with full paths
      foreach ($fg in $modeConfig.fileGroupPathMapping.Keys) {
        $basePath = $modeConfig.fileGroupPathMapping[$fg]

        # Store base path variable
        $varName = "${fg}_PATH"
        $sqlCmdVars[$varName] = $basePath
        Write-Verbose "SQLCMD Variable: `$($varName) = $basePath"

        # Build full file path variables for each file in this filegroup
        # Also build SIZE and GROWTH variables from config or metadata
        if ($fileGroupFiles.ContainsKey($fg)) {
          $fileIdx = 0
          foreach ($fileName in $fileGroupFiles[$fg]) {
            $fileIdx++
            # Use numeric suffix for multiple files per FileGroup (consistent with auto-remap behavior)
            if ($fileIdx -le 1) {
              $fileVarName = "${fg}_PATH_FILE"
              $sizeVarName = "${fg}_SIZE"
              $growthVarName = "${fg}_GROWTH"
            }
            else {
              $fileVarName = "{0}_PATH_FILE{1}" -f $fg, $fileIdx
              $sizeVarName = "{0}_SIZE{1}" -f $fg, $fileIdx
              $growthVarName = "{0}_GROWTH{1}" -f $fg, $fileIdx
            }
            # Use sanitized database name + original file name for uniqueness
            $uniqueFileName = "${sanitizedDbName}_${fileName}"
            $fullPath = "${basePath}${pathSeparator}${uniqueFileName}.ndf"
            $sqlCmdVars[$fileVarName] = $fullPath
            Write-Verbose "SQLCMD Variable: `$($fileVarName) = $fullPath"

            # Get SIZE and GROWTH values from config or metadata using helper function
            $fileSizeValues = Get-FileGroupFileSizeValues `
              -FileGroupName $fg `
              -FileName $fileName `
              -FgSizeDefaults $fgSizeDefaults `
              -ExportMetadata $exportMetadata

            $sqlCmdVars[$sizeVarName] = "$($fileSizeValues.SizeKB)KB"
            $sqlCmdVars[$growthVarName] = $fileSizeValues.GrowthValue
            Write-Verbose "SQLCMD Variable: `$($sizeVarName) = $($fileSizeValues.SizeKB)KB"
            Write-Verbose "SQLCMD Variable: `$($growthVarName) = $($fileSizeValues.GrowthValue)"
          }
        }
      }
    }
  }

  # Auto-remap FileGroup paths in Dev mode with autoRemap strategy
  if ($ImportMode -eq 'Dev' -and
    $sqlCmdVars.Count -eq 0 -and
    '00_FileGroups' -in $includedFolders) {

    $defaultDataPath = Get-DefaultDataPath -Connection $script:SharedConnection

    if ($defaultDataPath) {
      $fileGroupScript = Join-Path $SourcePath '00_FileGroups' '001_FileGroups.sql'
      if (Test-Path $fileGroupScript) {
        Write-Output "[INFO] Auto-remapping FileGroup paths to: $defaultDataPath"

        # SECURITY: Sanitize database name for use in filesystem paths
        $sanitizedDbName = $Database -replace '[^a-zA-Z0-9_-]', '_'

        # Parse FileGroup file to extract names
        $currentFG = $null
        $currentFileName = $null
        $fileIndex = @{}  # Track file count per FileGroup for uniqueness
        $currentFGType = 'Standard'  # Track FileGroup type (Standard vs MemoryOptimized)

        foreach ($line in (Get-Content $fileGroupScript)) {
          if ($line -match '-- FileGroup: (.+)') {
            $fgName = $matches[1].Trim()

            # SECURITY: Sanitize FileGroup name to prevent injection attacks
            # SQL Server identifiers can contain @, #, $, but we exclude these because:
            # 1) SQLCMD variable names must be valid PowerShell variable names
            # 2) Filesystem paths should avoid special characters for cross-platform safety
            # 3) Prevents potential injection via special character sequences
            if ($fgName -notmatch '^[a-zA-Z0-9_-]+$') {
              Write-Warning "[WARNING] FileGroup name '$fgName' contains unsafe characters. Skipping."
              $currentFG = $null
              continue
            }

            $currentFG = $fgName
            $fileIndex[$currentFG] = 0
            $currentFGType = 'Standard'  # Reset for new FileGroup
          }
          elseif ($line -match '-- Type:\s*(MemoryOptimizedDataFileGroup)') {
            $currentFGType = 'MemoryOptimized'
          }
          elseif ($line -match '-- Type:\s*(RowsFileGroup|FileStreamDataFileGroup)') {
            $currentFGType = 'Standard'
          }
          elseif ($line -match '-- File: (.+)' -and $currentFG) {
            $originalFileName = $matches[1].Trim()

            # SECURITY: Sanitize filename to prevent SQL injection via SQLCMD variable substitution
            # Only allow alphanumeric, dash, underscore, and period for safe filesystem names
            if ($originalFileName -notmatch '^[a-zA-Z0-9_.-]+$') {
              Write-Warning "[WARNING] FileGroup file name '$originalFileName' contains unsafe characters. Skipping."
              continue
            }

            $fileIndex[$currentFG]++
            $currentFileName = $originalFileName

            # Build unique filename: DatabaseName_FileGroupName_OriginalName
            $uniqueFileName = "${sanitizedDbName}_${currentFG}_${originalFileName}"

            # Memory-optimized FileGroups use directories (no extension)
            # Regular FileGroups use .ndf files
            if ($currentFGType -eq 'MemoryOptimized') {
              $fullPath = "${defaultDataPath}${pathSeparator}${uniqueFileName}"
            } else {
              $fullPath = "${defaultDataPath}${pathSeparator}${uniqueFileName}.ndf"
            }

            # Set the SQLCMD variables (PATH, SIZE, GROWTH)
            # Preserve original behavior for first file, add numeric suffix for additional files
            $index = $fileIndex[$currentFG]
            if ($index -le 1) {
              $pathVarName = "${currentFG}_PATH_FILE"
              $sizeVarName = "${currentFG}_SIZE"
              $growthVarName = "${currentFG}_GROWTH"
            }
            else {
              $pathVarName = "{0}_PATH_FILE{1}" -f $currentFG, $index
              $sizeVarName = "{0}_SIZE{1}" -f $currentFG, $index
              $growthVarName = "{0}_GROWTH{1}" -f $currentFG, $index
            }
            $sqlCmdVars[$pathVarName] = $fullPath
            Write-Verbose "  Auto-mapped: `$($pathVarName) = $fullPath"

            # Memory-optimized FileGroups don't use SIZE/GROWTH - use special marker
            if ($currentFGType -eq 'MemoryOptimized') {
              # Mark these for special handling in Invoke-SqlScript
              $sqlCmdVars[$sizeVarName] = '__MEMORY_OPTIMIZED_REMOVE__'
              $sqlCmdVars[$growthVarName] = '__MEMORY_OPTIMIZED_REMOVE__'
              Write-Verbose "  Memory-optimized FileGroup - SIZE/GROWTH will be removed"
            } else {
              # Get SIZE and GROWTH values from config or metadata using helper function
              $fileSizeValues = Get-FileGroupFileSizeValues `
                -FileGroupName $currentFG `
                -FileName $originalFileName `
                -FgSizeDefaults $fgSizeDefaults `
                -ExportMetadata $exportMetadata

              $sqlCmdVars[$sizeVarName] = "$($fileSizeValues.SizeKB)KB"
              $sqlCmdVars[$growthVarName] = $fileSizeValues.GrowthValue
              Write-Verbose "  Auto-mapped: `$($sizeVarName) = $($fileSizeValues.SizeKB)KB"
              Write-Verbose "  Auto-mapped: `$($growthVarName) = $($fileSizeValues.GrowthValue)"
            }
          }
        }
      }
    }
    else {
      Write-Warning "[WARNING] Could not auto-detect default data path"
      Write-Warning "  Falling back to FileGroup strategy: removeToPrimary (all FileGroups will map to PRIMARY)."
      $sqlCmdVars['__RemapFileGroupsToPrimary__'] = $true
      Write-Warning "  To customize FileGroup paths, provide fileGroupPathMapping in config or define SQLCMD variables explicitly."

      # Bug 6 Fix: Even in fallback mode, create memory-optimized FileGroups (they can't be remapped to PRIMARY)
      $fileGroupScript = Join-Path $SourcePath '00_FileGroups' '001_FileGroups.sql'
      if (Test-Path $fileGroupScript) {
        $memoryOptimizedSql = Get-MemoryOptimizedFileGroupSql -FilePath $fileGroupScript
        if ($memoryOptimizedSql.Count -gt 0) {
          Write-Output "[INFO] Found $($memoryOptimizedSql.Count) memory-optimized FileGroup block(s) - these cannot be remapped to PRIMARY"
          Write-Output "[INFO] Creating required memory-optimized FileGroups..."

          foreach ($sqlBlock in $memoryOptimizedSql) {
            # Escape the database name to prevent SQL injection via ] characters
            $escapedDbName = Get-EscapedSqlIdentifier -Name $Database
            $sql = $sqlBlock -replace '\bALTER\s+DATABASE\s+CURRENT\b', "ALTER DATABASE [$escapedDbName]"
            try {
              $script:SharedConnection.ConnectionContext.ExecuteNonQuery($sql) | Out-Null
              Write-Verbose "  Executed memory-optimized FileGroup SQL block"
            }
            catch {
              Write-Host "  [ERROR] Failed to create memory-optimized FileGroup: $_" -ForegroundColor Red
            }
          }
          Write-Output "[SUCCESS] Memory-optimized FileGroup(s) created"
        }
      }
    }
  }

  # Set flag for removeToPrimary transformations
  if ($ImportMode -eq 'Dev') {
    $devSettings = if ($config -and $config.import -and $config.import.developerMode) {
      $config.import.developerMode
    }
    else {
      @{ fileGroupStrategy = 'autoRemap' }
    }

    # Use Get-SafeProperty for compatibility with both hashtables and PSCustomObjects from YAML
    $fileGroupStrategy = Get-SafeProperty -Object $devSettings -PropertyName 'fileGroupStrategy'
    if (-not $fileGroupStrategy) {
      $fileGroupStrategy = 'autoRemap'
    }

    # Check for convertLoginsToContained setting
    $convertLoginsToContained = Get-SafeProperty -Object $devSettings -PropertyName 'convertLoginsToContained'
    if ($convertLoginsToContained -eq $true) {
      $sqlCmdVars['__ConvertLoginsToContained__'] = $true
      Write-Output "[INFO] Login conversion: enabled - FOR LOGIN users will be converted to WITHOUT LOGIN (contained)"
    }

    if ($fileGroupStrategy -eq 'removeToPrimary') {
      $sqlCmdVars['__RemapFileGroupsToPrimary__'] = $true
      Write-Output "[INFO] FileGroup strategy: removeToPrimary - all FileGroup references will map to PRIMARY"

      # Bug 6 Fix: Memory-optimized FileGroups cannot be remapped to PRIMARY - they must be created
      $fileGroupScript = Join-Path $SourcePath '00_FileGroups' '001_FileGroups.sql'
      if (Test-Path $fileGroupScript) {
        $memoryOptimizedSql = Get-MemoryOptimizedFileGroupSql -FilePath $fileGroupScript
        if ($memoryOptimizedSql.Count -gt 0) {
          Write-Output "[INFO] Found $($memoryOptimizedSql.Count) memory-optimized FileGroup block(s) - these cannot be remapped to PRIMARY"
          Write-Output "[INFO] Creating required memory-optimized FileGroups..."

          # Get default data path for memory-optimized container
          $memOptDataPath = Get-DefaultDataPath -Connection $script:SharedConnection
          if (-not $memOptDataPath) {
            Write-Warning "[WARNING] Could not detect default data path - memory-optimized FileGroup may fail"
            $memOptDataPath = 'C:\Data'  # Fallback
          }

          # Determine path separator based on detected path format
          $memOptPathSep = if ($memOptDataPath -match '^/') { '/' } else { '\' }

          # SECURITY: Sanitize database name for filesystem path
          $sanitizedDbName = $Database -replace '[^a-zA-Z0-9_-]', '_'

          foreach ($sqlBlock in $memoryOptimizedSql) {
            # Replace ALTER DATABASE CURRENT with actual database name
            # Escape the database name to prevent SQL injection via ] characters
            $escapedDbName = Get-EscapedSqlIdentifier -Name $Database
            $sql = $sqlBlock -replace '\bALTER\s+DATABASE\s+CURRENT\b', "ALTER DATABASE [$escapedDbName]"

            # Replace SQLCMD variables for memory-optimized FileGroups
            # Pattern: $(FG_NAME_PATH_FILE), $(FG_NAME_SIZE), $(FG_NAME_GROWTH)
            if ($sql -match '\$\(([A-Za-z0-9_]+)_PATH_FILE\)') {
              $fgName = $matches[1]
              # Memory-optimized uses a folder, not a file (no extension)
              $containerPath = "${memOptDataPath}${memOptPathSep}${sanitizedDbName}_${fgName}"
              $varPattern = [regex]::Escape("`$(" + $fgName + "_PATH_FILE)")
              $sql = $sql -replace $varPattern, $containerPath

              # Memory-optimized containers don't use SIZE/FILEGROWTH - remove these clauses entirely
              # SIZE = value and , FILEGROWTH = value need to be removed
              $sql = $sql -replace ',?\s*SIZE\s*=\s*\$\([A-Za-z0-9_]+_SIZE\)', ''
              $sql = $sql -replace ',?\s*FILEGROWTH\s*=\s*\$\([A-Za-z0-9_]+_GROWTH\)', ''
            }

            try {
              $script:SharedConnection.ConnectionContext.ExecuteNonQuery($sql) | Out-Null
              Write-Verbose "  Executed memory-optimized FileGroup SQL block"
            }
            catch {
              Write-Host "  [ERROR] Failed to create memory-optimized FileGroup: $_" -ForegroundColor Red
              # Continue - don't abort the entire import for this
            }
          }
          Write-Output "[SUCCESS] Memory-optimized FileGroup(s) created"
        }
      }
    }
  }
  elseif ($ImportMode -eq 'Prod') {
    # Check for convertLoginsToContained in Prod mode (less common but supported)
    $prodSettings = if ($config -and $config.import -and $config.import.productionMode) {
      $config.import.productionMode
    }
    else {
      @{}
    }

    if ($prodSettings.ContainsKey('convertLoginsToContained') -and $prodSettings.convertLoginsToContained -eq $true) {
      $sqlCmdVars['__ConvertLoginsToContained__'] = $true
      Write-Output "[INFO] Login conversion: enabled - FOR LOGIN users will be converted to WITHOUT LOGIN (contained)"
    }
  }

  # Check for stripFilestream setting (command-line parameter takes priority over config)
  # FILESTREAM is Windows-only feature - stripping allows imports to Linux/container targets
  $stripFilestreamEnabled = $script:StripFilestreamEnabled
  if (-not $stripFilestreamEnabled) {
    # Check config file for mode-specific setting
    $modeSettings = if ($ImportMode -eq 'Dev') {
      if ($config -and $config.import -and $config.import.developerMode) { $config.import.developerMode } else { @{} }
    }
    else {
      if ($config -and $config.import -and $config.import.productionMode) { $config.import.productionMode } else { @{} }
    }
    if ($modeSettings.ContainsKey('stripFilestream') -and $modeSettings.stripFilestream -eq $true) {
      $stripFilestreamEnabled = $true
    }
  }
  if ($stripFilestreamEnabled) {
    $sqlCmdVars['__StripFilestream__'] = $true
    Write-Output "[INFO] FILESTREAM stripping: enabled - FILESTREAM features will be removed (Linux/container compatibility)"
    Write-Output "       FILESTREAM_ON clauses will be removed, VARBINARY(MAX) FILESTREAM -> VARBINARY(MAX)"
  }

  # Check for stripAlwaysEncrypted setting (command-line parameter takes priority over config)
  # Always Encrypted requires external key stores (Azure Key Vault, Windows Certificate Store, etc.)
  # Stripping allows imports to targets without access to the original key store
  $stripAlwaysEncryptedEnabled = $script:StripAlwaysEncryptedEnabled
  if (-not $stripAlwaysEncryptedEnabled) {
    # Check config file for mode-specific setting
    $modeSettings = if ($ImportMode -eq 'Dev') {
      if ($config -and $config.import -and $config.import.developerMode) { $config.import.developerMode } else { @{} }
    }
    else {
      if ($config -and $config.import -and $config.import.productionMode) { $config.import.productionMode } else { @{} }
    }
    if ($modeSettings.ContainsKey('stripAlwaysEncrypted') -and $modeSettings.stripAlwaysEncrypted -eq $true) {
      $stripAlwaysEncryptedEnabled = $true
    }
  }
  if ($stripAlwaysEncryptedEnabled) {
    $sqlCmdVars['__StripAlwaysEncrypted__'] = $true
    Write-Output "[INFO] Always Encrypted stripping: enabled - CMK, CEK, and ENCRYPTED WITH clauses will be removed"
    Write-Output "       Encrypted columns will become regular (unencrypted) columns"
  }

  # Resolve encryption secrets from config (for Database Master Key, Symmetric Keys, etc.)
  # This allows importing databases with encryption objects by providing passwords from secure sources
  $modeSettingsForSecrets = if ($ImportMode -eq 'Dev') {
    if ($config -and $config.import -and $config.import.developerMode) { $config.import.developerMode } else { @{} }
  }
  else {
    if ($config -and $config.import -and $config.import.productionMode) { $config.import.productionMode } else { @{} }
  }
  $encryptionSecrets = Get-EncryptionSecrets -ModeSettings $modeSettingsForSecrets -ImportMode $ImportMode
  if ($encryptionSecrets) {
    $sqlCmdVars['__EncryptionSecrets__'] = $encryptionSecrets
    $secretsInfo = @()
    if ($encryptionSecrets.databaseMasterKey) { $secretsInfo += "DMK" }
    if ($encryptionSecrets.symmetricKeys.Count -gt 0) { $secretsInfo += "$($encryptionSecrets.symmetricKeys.Count) symmetric key(s)" }
    if ($encryptionSecrets.certificates.Count -gt 0) { $secretsInfo += "$($encryptionSecrets.certificates.Count) certificate(s)" }
    if ($encryptionSecrets.applicationRoles.Count -gt 0) { $secretsInfo += "$($encryptionSecrets.applicationRoles.Count) app role(s)" }
    if ($secretsInfo.Count -gt 0) {
      Write-Output "[INFO] Encryption secrets: loaded ($($secretsInfo -join ', '))"
    }
  }

  # Report skipped folders if any
  if ($skippedFolders.Count -gt 0) {
    Write-Output "[INFO] Skipped $($skippedFolders.Count) folder(s) due to $ImportMode mode settings:"
    foreach ($folder in $skippedFolders) {
      $reason = switch ($folder) {
        '00_FileGroups' { 'FileGroups (environment-specific)' }
        '02_DatabaseConfiguration' { 'Database Scoped Configurations (environment-specific)' }
        '17_ExternalData' { 'External Data Sources (environment-specific)' }
        '21_Data' { 'Data not requested' }
        default { $folder }
      }
      Write-Output "  - $reason"
    }
  }

  Write-Output ''

  # Apply scripts
  Write-Output 'Applying scripts...'
  Write-Output '───────────────────────────────────────────────'
  Write-Log "Starting script execution - $($scripts.Count) total scripts" -Severity INFO
  Write-Verbose "Total scripts to process: $($scripts.Count)"
  if ($scripts.Count -gt 0) {
    Write-Verbose "First script: $($scripts[0].FullName)"
    Write-Verbose "Last script: $($scripts[-1].FullName)"
  }
  $successCount = 0
  $failureCount = 0
  $skipCount = 0

  # Track if we need to handle foreign keys for data import
  # Identify data scripts by filename pattern (*.data.sql) rather than folder name
  # This is more resilient to folder structure changes
  $dataScripts = $scripts | Where-Object { $_.Name -match '\.data\.sql$' }
  $nonDataScripts = $scripts | Where-Object { $_.Name -notmatch '\.data\.sql$' }

  # Track counts for metrics
  if ($script:CollectMetrics) {
    $script:Metrics.dataScriptsCount = $dataScripts.Count
    $script:Metrics.nonDataScriptsCount = $nonDataScripts.Count
    $script:ScriptStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
  }

  Write-Verbose "Found $($nonDataScripts.Count) non-data script(s) and $($dataScripts.Count) data script(s)"

  # Reuse the shared connection created during preliminary checks
  # It's already connected to the target database at this point
  if (-not $script:SharedConnection -or -not $script:SharedConnection.ConnectionContext.IsOpen) {
    Write-Error "[ERROR] Shared connection not available for script execution"
    exit 1
  }
  Write-Verbose "Reusing shared SMO connection for script execution"

  # Get dependency retry settings from config
  $retryEnabled = $true  # Default enabled
  $retryMaxAttempts = 10  # Default 10 retries
  $retryObjectTypes = @('Functions', 'StoredProcedures', 'Views')  # Default types

  if ($config -and $config.import -and $config.import.dependencyRetries) {
    $retryConfig = $config.import.dependencyRetries
    if ($retryConfig.ContainsKey('enabled')) {
      $retryEnabled = $retryConfig.enabled
    }
    if ($retryConfig.ContainsKey('maxRetries')) {
      $retryMaxAttempts = $retryConfig.maxRetries
    }
    if ($retryConfig.ContainsKey('objectTypes') -and $retryConfig.objectTypes.Count -gt 0) {
      $retryObjectTypes = $retryConfig.objectTypes
    }
  }

  Write-Verbose "[RETRY] Dependency retry enabled: $retryEnabled"
  Write-Verbose "[RETRY] Max retry attempts: $retryMaxAttempts"
  Write-Verbose "[RETRY] Retry object types: $($retryObjectTypes -join ', ')"

  # Identify programmability scripts that need dependency retry logic
  # These scripts are from folders: 14_Programmability/02_Functions, etc.
  # Match folder patterns to retry object types
  $folderPatternMap = @{
    'Functions'        = '14_Programmability[\\/]02_Functions'
    'StoredProcedures' = '14_Programmability[\\/]03_StoredProcedures'
    'Views'            = '14_Programmability[\\/]05_Views'
    'Synonyms'         = '14_Programmability[\\/]06_Synonyms'
    'TableTriggers'    = '14_Programmability[\\/]04_TableTriggers'
    'DatabaseTriggers' = '14_Programmability[\\/]01_DatabaseTriggers'
  }

  # Build regex pattern to match programmability folders
  $retryFolderPatterns = @()
  foreach ($objectType in $retryObjectTypes) {
    if ($folderPatternMap.ContainsKey($objectType)) {
      $retryFolderPatterns += $folderPatternMap[$objectType]
    }
  }

  # If no specific patterns, match all programmability subfolder scripts
  if ($retryFolderPatterns.Count -eq 0 -and $retryEnabled) {
    $retryFolderPatterns += '14_Programmability'
  }

  $retryFolderRegex = if ($retryFolderPatterns.Count -gt 0) {
    "($($retryFolderPatterns -join '|'))"
  }
  else {
    '^$'  # Match nothing if no retry types configured
  }

  Write-Verbose "[RETRY] Folder pattern regex: $retryFolderRegex"

  # Split scripts into programmability (needs retry), security policies (after programmability), and structural (no retry)
  # Security policies depend on programmability objects (functions, etc.) so must be processed last
  $programmabilityScripts = @()
  $securityPolicyScripts = @()
  $structuralScripts = @()

  if ($retryEnabled) {
    foreach ($script in $nonDataScripts) {
      # Check if script is in a programmability folder
      $relativePath = $script.FullName.Substring($SourcePath.Length).TrimStart('\', '/')
      if ($relativePath -match '20_SecurityPolicies') {
        # Security policies depend on programmability objects - process after retry
        $securityPolicyScripts += $script
        Write-Verbose "[RETRY] Deferred security policy (depends on programmability): $($script.Name)"
      }
      elseif ($relativePath -match $retryFolderRegex) {
        $programmabilityScripts += $script
        Write-Verbose "[RETRY] Marked for retry: $($script.Name)"
      }
      else {
        $structuralScripts += $script
      }
    }
  }
  else {
    # Retry disabled - treat all as structural (no retry), but still defer security policies to end
    foreach ($script in $nonDataScripts) {
      $relativePath = $script.FullName.Substring($SourcePath.Length).TrimStart('\', '/')
      if ($relativePath -match '20_SecurityPolicies') {
        $securityPolicyScripts += $script
      }
      else {
        $structuralScripts += $script
      }
    }
  }

  Write-Verbose "[RETRY] Found $($programmabilityScripts.Count) programmability scripts, $($securityPolicyScripts.Count) security policy scripts, $($structuralScripts.Count) structural scripts"

  # Track current folder for error reporting
  $currentFolder = ''
  # Flag to track if we should abort after structural failures (but still write error log)
  $abortAfterStructuralFailure = $false

  # Process structural scripts first (no retry logic - these define structure)
  foreach ($scriptFile in $structuralScripts) {
    # Skip remaining scripts if we've already decided to abort
    if ($abortAfterStructuralFailure) { break }

    # Extract folder from path for error reporting
    $relativePath = $scriptFile.FullName -replace [regex]::Escape($SourcePath), '' -replace '^[\\/]', ''
    $scriptFolder = ($relativePath -split '[\\/]')[0]
    if ($scriptFolder -ne $currentFolder) {
      $currentFolder = $scriptFolder
    }

    $result = Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "Script: $($scriptFile.Name)" -ScriptBlock {
      Invoke-SqlScript -FilePath $scriptFile.FullName -ServerName $Server `
        -DatabaseName $Database -Cred $Credential -Timeout $effectiveCommandTimeout -Show:$ShowSQL `
        -SqlCmdVariables $sqlCmdVars -Config $config -Connection $script:SharedConnection
    }

    if ($result -eq $true) {
      $successCount++
    }
    elseif ($result -eq -1) {
      $failureCount++

      # Get and display error immediately (structural failures are fatal)
      $errorMsg = if ($script:LastScriptError) { $script:LastScriptError } else { 'Unknown error' }
      $shortError = $errorMsg -split "`n" | Where-Object { $_ -match 'Error \d+:|Message:' } | Select-Object -First 1
      if (-not $shortError) { $shortError = ($errorMsg -split "`n")[0] }
      $shortError = $shortError.Trim() -replace '^\s*-?\s*', ''

      Write-Host "  [ERROR] $($scriptFile.Name)" -ForegroundColor Red
      Write-Host "    $shortError" -ForegroundColor DarkRed

      # Record for final summary
      Add-FailedScript -ScriptName $scriptFile.Name -ErrorMessage $errorMsg -Folder $currentFolder -IsFinal $true

      if (-not $ContinueOnError) {
        # Set flag to abort - but don't throw error so we can still write error log
        $abortAfterStructuralFailure = $true
        Write-Host "[ERROR] Structural script failed. Aborting import after writing error log." -ForegroundColor Red
      }
    }
    else {
      $skipCount++
    }
  }

  # Process programmability scripts with dependency retry logic (only if no structural failures or abort flag)
  if ($programmabilityScripts.Count -gt 0 -and -not $abortAfterStructuralFailure -and ($failureCount -eq 0 -or $ContinueOnError)) {
    $retryResults = Invoke-ScriptsWithDependencyRetries `
      -Scripts $programmabilityScripts `
      -MaxRetries $retryMaxAttempts `
      -Server $Server `
      -Database $Database `
      -Credential $Credential `
      -Timeout $effectiveCommandTimeout `
      -ShowSQL:$ShowSQL `
      -SqlCmdVariables $sqlCmdVars `
      -Config $config `
      -Connection $script:SharedConnection `
      -ContinueOnError:$ContinueOnError `
      -MaxAttempts $effectiveMaxRetries `
      -InitialDelaySeconds $effectiveRetryDelay

    $successCount += $retryResults.Success
    $failureCount += $retryResults.Failure
    $skipCount += $retryResults.Skip

    # If programmability scripts failed and not in ContinueOnError mode, set abort flag
    if ($retryResults.Failure -gt 0 -and -not $ContinueOnError) {
      $abortAfterStructuralFailure = $true
    }
  }
  elseif ($programmabilityScripts.Count -gt 0 -and ($abortAfterStructuralFailure -or $failureCount -gt 0)) {
    Write-Warning "[WARNING] Skipping $($programmabilityScripts.Count) programmability script(s) due to earlier failures"
    $skipCount += $programmabilityScripts.Count
  }

  # Process security policy scripts AFTER programmability objects (they depend on functions/procedures)
  if ($securityPolicyScripts.Count -gt 0 -and -not $abortAfterStructuralFailure -and ($failureCount -eq 0 -or $ContinueOnError)) {
    Write-Output ''
    Write-Output "[INFO] Processing $($securityPolicyScripts.Count) security policy script(s)..."
    foreach ($scriptFile in $securityPolicyScripts) {
      if ($abortAfterStructuralFailure) { break }

      $result = Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "Script: $($scriptFile.Name)" -ScriptBlock {
        Invoke-SqlScript -FilePath $scriptFile.FullName -ServerName $Server `
          -DatabaseName $Database -Cred $Credential -Timeout $effectiveCommandTimeout -Show:$ShowSQL `
          -SqlCmdVariables $sqlCmdVars -Config $config -Connection $script:SharedConnection
      }

      if ($result -eq $true) {
        $successCount++
      }
      elseif ($result -eq -1) {
        $failureCount++

        # Get error details
        $errorMsg = if ($script:LastScriptError) { $script:LastScriptError } else { 'Unknown error' }
        $shortError = $errorMsg -split "`n" | Where-Object { $_ -match 'Error \d+:|Message:' } | Select-Object -First 1
        if (-not $shortError) { $shortError = ($errorMsg -split "`n")[0] }
        $shortError = $shortError.Trim() -replace '^\s*-?\s*', ''

        Write-Host "  [ERROR] $($scriptFile.Name)" -ForegroundColor Red
        Write-Host "    $shortError" -ForegroundColor DarkRed

        # Record for final summary
        Add-FailedScript -ScriptName $scriptFile.Name -ErrorMessage $errorMsg -Folder '15_SecurityPolicies' -IsFinal $true

        if (-not $ContinueOnError) {
          $abortAfterStructuralFailure = $true
          Write-Host "[ERROR] Security policy script failed. Aborting import after writing error log." -ForegroundColor Red
          break
        }
      }
      else {
        $skipCount++
      }
    }
  }
  elseif ($securityPolicyScripts.Count -gt 0 -and ($abortAfterStructuralFailure -or $failureCount -gt 0)) {
    Write-Warning "[WARNING] Skipping $($securityPolicyScripts.Count) security policy script(s) due to earlier failures"
    $skipCount += $securityPolicyScripts.Count
  }

  # If we have data scripts and no failures so far (and no abort flag), handle them with FK constraints disabled
  Write-Verbose "FK disable check: dataScripts.Count=$($dataScripts.Count), failureCount=$failureCount, abortFlag=$abortAfterStructuralFailure"
  if ($dataScripts.Count -gt 0 -and $failureCount -eq 0 -and -not $abortAfterStructuralFailure) {
    Write-Output ''
    Write-Output 'Preparing for data import...'
    Write-Verbose "Attempting to disable foreign key constraints..."

    # Disable all foreign key constraints
    # Get list of FKs and disable them individually
    $smServer = $null
    if ($script:CollectMetrics) { $script:FKStopwatch = [System.Diagnostics.Stopwatch]::StartNew() }
    try {
      Write-Verbose "Connecting to $Server database $Database to disable FKs..."
      $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
      if ($Credential) {
        $smServer.ConnectionContext.set_LoginSecure($false)
        $smServer.ConnectionContext.set_Login($Credential.UserName)
        $smServer.ConnectionContext.set_SecurePassword($Credential.Password)
      }
      $smServer.ConnectionContext.ConnectTimeout = $effectiveConnectionTimeout
      $smServer.ConnectionContext.DatabaseName = $Database

      # Apply TrustServerCertificate - resolved from CLI switch, config connection section, or config root
      if ($script:TrustServerCertificateEnabled) {
        $smServer.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($config -and $config.ContainsKey('trustServerCertificate')) {
        $smServer.ConnectionContext.TrustServerCertificate = $config.trustServerCertificate
      }

      $smServer.ConnectionContext.Connect()
      Write-Verbose "Connected to SQL Server successfully"

      $db = $smServer.Databases[$Database]
      Write-Verbose "Found database: $($db.Name), Tables count: $($db.Tables.Count)"
      $fkCount = 0

      foreach ($table in $db.Tables) {
        Write-Verbose "Checking table: $($table.Schema).$($table.Name), FK count: $($table.ForeignKeys.Count)"
        foreach ($fk in $table.ForeignKeys) {
          Write-Verbose "  FK: $($fk.Name), IsEnabled: $($fk.IsEnabled)"
          if ($fk.IsEnabled) {
            $alterSql = "ALTER TABLE [$($table.Schema)].[$($table.Name)] NOCHECK CONSTRAINT [$($fk.Name)]"
            Write-Verbose "  Executing: $alterSql"
            $smServer.ConnectionContext.ExecuteNonQuery($alterSql)
            $fkCount++
          }
        }
      }

      if ($fkCount -gt 0) {
        Write-Output "[SUCCESS] Disabled $fkCount foreign key constraint(s) for data import"
      }
      else {
        Write-Output '[INFO] No foreign key constraints to disable'
      }
    }
    catch {
      Write-Warning "[WARNING] Could not disable foreign keys: $_"
      Write-Warning '  Data import may fail if files are not in dependency order'
      Write-Warning '  Attempting to continue with data import...'
    }
    finally {
      if ($smServer -and $smServer.ConnectionContext.IsOpen) {
        $smServer.ConnectionContext.Disconnect()
      }
      if ($script:CollectMetrics -and $script:FKStopwatch) {
        $script:FKStopwatch.Stop()
        $script:Metrics.fkDisableSeconds = $script:FKStopwatch.Elapsed.TotalSeconds
      }
    }

    Write-Output ''
    Write-Output 'Importing data files...'

    # Process data scripts
    foreach ($scriptFile in $dataScripts) {
      $result = Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "Data Script: $($scriptFile.Name)" -ScriptBlock {
        Invoke-SqlScript -FilePath $scriptFile.FullName -ServerName $Server `
          -DatabaseName $Database -Cred $Credential -Timeout $effectiveCommandTimeout -Show:$ShowSQL `
          -SqlCmdVariables $sqlCmdVars -Config $config -Connection $script:SharedConnection
      }

      if ($result -eq $true) {
        $successCount++
      }
      elseif ($result -eq -1) {
        $failureCount++

        # Get error details
        $errorMsg = if ($script:LastScriptError) { $script:LastScriptError } else { 'Unknown error' }
        $shortError = $errorMsg -split "`n" | Where-Object { $_ -match 'Error \d+:|Message:' } | Select-Object -First 1
        if (-not $shortError) { $shortError = ($errorMsg -split "`n")[0] }
        $shortError = $shortError.Trim() -replace '^\s*-?\s*', ''

        Write-Host "  [ERROR] $($scriptFile.Name)" -ForegroundColor Red
        Write-Host "    $shortError" -ForegroundColor DarkRed

        # Record for final summary
        Add-FailedScript -ScriptName $scriptFile.Name -ErrorMessage $errorMsg -Folder '16_Data' -IsFinal $true

        if (-not $ContinueOnError) {
          break
        }
      }
      else {
        $skipCount++
      }
    }

    # Re-enable all foreign key constraints and validate data
    $smServer = $null
    if ($script:CollectMetrics) { $script:FKStopwatch = [System.Diagnostics.Stopwatch]::StartNew() }
    try {
      $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
      if ($Credential) {
        $smServer.ConnectionContext.set_LoginSecure($false)
        $smServer.ConnectionContext.set_Login($Credential.UserName)
        $smServer.ConnectionContext.set_SecurePassword($Credential.Password)
      }
      $smServer.ConnectionContext.ConnectTimeout = $effectiveConnectionTimeout
      $smServer.ConnectionContext.DatabaseName = $Database

      # Apply TrustServerCertificate - resolved from CLI switch, config connection section, or config root
      if ($script:TrustServerCertificateEnabled) {
        $smServer.ConnectionContext.TrustServerCertificate = $true
      }
      elseif ($config -and $config.ContainsKey('trustServerCertificate')) {
        $smServer.ConnectionContext.TrustServerCertificate = $config.trustServerCertificate
      }

      $smServer.ConnectionContext.Connect()

      $db = $smServer.Databases[$Database]
      $fkCount = 0
      $errorCount = 0

      foreach ($table in $db.Tables) {
        foreach ($fk in $table.ForeignKeys) {
          if (-not $fk.IsEnabled) {
            try {
              $alterSql = "ALTER TABLE [$($table.Schema)].[$($table.Name)] WITH CHECK CHECK CONSTRAINT [$($fk.Name)]"
              $smServer.ConnectionContext.ExecuteNonQuery($alterSql)
              $fkCount++
            }
            catch {
              Write-Error "  [ERROR] Failed to re-enable FK $($fk.Name) on $($table.Schema).$($table.Name): $_"
              $errorCount++
            }
          }
        }
      }

      if ($errorCount -gt 0) {
        Write-Error "[ERROR] Foreign key constraint validation failed ($errorCount errors) - data may violate referential integrity"
        $failureCount++
      }
      elseif ($fkCount -gt 0) {
        Write-Output "[SUCCESS] Re-enabled and validated $fkCount foreign key constraint(s)"
      }
      else {
        Write-Output '[INFO] No foreign key constraints to re-enable'
      }
    }
    catch {
      Write-Error "[ERROR] Error re-enabling foreign keys: $_"
      $failureCount++
    }
    finally {
      if ($smServer -and $smServer.ConnectionContext.IsOpen) {
        $smServer.ConnectionContext.Disconnect()
      }
      if ($script:CollectMetrics -and $script:FKStopwatch) {
        $script:FKStopwatch.Stop()
        $script:Metrics.fkEnableSeconds = $script:FKStopwatch.Elapsed.TotalSeconds
      }
    }
  }

  # Close the shared connection
  if ($script:SharedConnection -and $script:SharedConnection.ConnectionContext.IsOpen) {
    $script:SharedConnection.ConnectionContext.Disconnect()
    Write-Verbose "Closed shared SMO connection"
  }

  # Stop script execution timing
  if ($script:CollectMetrics -and $script:ScriptStopwatch) {
    $script:ScriptStopwatch.Stop()
    $script:Metrics.scriptExecutionSeconds = $script:ScriptStopwatch.Elapsed.TotalSeconds
  }

  Write-Output '───────────────────────────────────────────────'
  Write-Output ''
  Write-Output '═══════════════════════════════════════════════'
  Write-Output 'IMPORT SUMMARY'
  Write-Output '═══════════════════════════════════════════════'
  Write-Output ''
  Write-Output "Import mode: $ImportMode"
  Write-Output "Target: $Server\$Database"
  Write-Output ''
  Write-Output "Execution results:"
  Write-Output "  [SUCCESS] Successful: $successCount script(s)"
  if ($skipCount -gt 0) {
    Write-Output "  [INFO] Skipped:   $skipCount script(s)"
  }
  if ($failureCount -gt 0) {
    Write-Output "  [ERROR] Failed:    $failureCount script(s)"
  }
  Write-Output ''

  # Report mode-specific decisions
  if ($skippedFolders.Count -gt 0) {
    Write-Output "Folders skipped due to $ImportMode mode:"
    foreach ($folder in $skippedFolders) {
      $reason = switch ($folder) {
        '00_FileGroups' { 'FileGroups (environment-specific, skipped in Dev mode)' }
        '02_DatabaseConfiguration' { 'Database Configurations (hardware-specific, skipped in Dev mode)' }
        '17_ExternalData' { 'External Data Sources (environment-specific, skipped in Dev mode)' }
        '21_Data' { 'Data not requested via -IncludeData flag' }
        default { $folder }
      }
      Write-Output "  - $reason"
    }
    Write-Output ''
  }

  # Check for manual actions needed
  $manualActions = @()

  # Check if FileGroups were in source but skipped
  $sourceFgPath = Join-Path $SourcePath '00_FileGroups'
  if ((Test-Path $sourceFgPath) -and ('00_FileGroups' -in $skippedFolders)) {
    $manualActions += "[INFO] FileGroups were exported but not imported (Dev mode)"
    $manualActions += "  Use -ImportMode Prod to import FileGroups (review file paths first)"
  }

  # Check if DB Configurations were in source but skipped
  $sourceDbConfigPath = Join-Path $SourcePath '02_DatabaseConfiguration'
  if ((Test-Path $sourceDbConfigPath) -and ('02_DatabaseConfiguration' -in $skippedFolders)) {
    $manualActions += "[INFO] Database Scoped Configurations were exported but not imported (Dev mode)"
    $manualActions += "  Use -ImportMode Prod to import configurations (review settings first)"
  }

  # Check if External Data was in source but skipped
  $sourceExtDataPath = Join-Path $SourcePath '17_ExternalData'
  if ((Test-Path $sourceExtDataPath) -and ('17_ExternalData' -in $skippedFolders)) {
    $manualActions += "[INFO] External Data Sources were exported but not imported (Dev mode)"
    $manualActions += "  Use -ImportMode Prod to import external data (review connection strings first)"
  }

  # Check for Database Scoped Credentials (never imported, always manual)
  $sourceCredsPath = Join-Path $SourcePath '02_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
  if (Test-Path $sourceCredsPath) {
    $credsContent = Get-Content $sourceCredsPath -Raw
    if ($credsContent -match 'CREATE DATABASE SCOPED CREDENTIAL') {
      $manualActions += "[ACTION REQUIRED] Database Scoped Credentials"
      $manualActions += "  Location: Source\\02_DatabaseConfiguration\002_DatabaseScopedCredentials.sql"
      $manualActions += "  Action: Manually create credentials with appropriate secrets on target server"
      $manualActions += "  Note: Credentials cannot be scripted with secrets - must be manually configured"
    }
  }

  # Check for RLS policies in the new location
  $sourceRlsPath = Join-Path $SourcePath '20_SecurityPolicies'
  $hasRlsPolicies = $false
  if (Test-Path $sourceRlsPath) {
    $rlsFiles = Get-ChildItem -Path $sourceRlsPath -Filter '*.sql' -ErrorAction SilentlyContinue
    if ($rlsFiles.Count -gt 0) {
      $hasRlsPolicies = $true
    }
  }

  if ($hasRlsPolicies) {
    $modeSettings = if ($ImportMode -eq 'Dev') {
      if ($config.import -and $config.import.developerMode) {
        $config.import.developerMode
      }
      else {
        @{ enableSecurityPolicies = $false }
      }
    }
    else {
      @{ enableSecurityPolicies = $true }
    }

    if (-not $modeSettings.enableSecurityPolicies) {
      $manualActions += "[INFO] Row-Level Security Policies were exported but not imported ($ImportMode mode)"
      $manualActions += "  RLS policies are disabled in Dev mode by default to simplify testing"
      $manualActions += "  Use -ImportMode Prod or configure enableSecurityPolicies = true in config file"
    }
  }

  if ($manualActions.Count -gt 0) {
    Write-Output "Manual actions and information:"
    Write-Output ''
    $manualActions | ForEach-Object { Write-Output $_ }
    Write-Output ''
  }

  if ($failureCount -gt 0) {
    # Write error log file
    $errorLogPath = Write-ErrorLog -SourcePath $SourcePath

    Write-Output ''
    Write-Host "[ERROR] Import completed with $failureCount error(s):" -ForegroundColor Red

    # Show error summary (up to 10 errors)
    $displayCount = [Math]::Min($script:FailedScripts.Count, 10)
    for ($i = 0; $i -lt $displayCount; $i++) {
      $failure = $script:FailedScripts[$i]
      Write-Host "  $($i + 1). $($failure.ScriptName) - $($failure.ErrorMessage)" -ForegroundColor Red
    }
    if ($script:FailedScripts.Count -gt 10) {
      Write-Host "  ... and $($script:FailedScripts.Count - 10) more error(s)" -ForegroundColor Red
    }

    if ($errorLogPath) {
      Write-Output ''
      Write-Output "See $errorLogPath for full error details."
    }

    Write-Output ''
    Write-Log "Import completed with $failureCount error(s)" -Severity ERROR
  }
  else {
    Write-Output '[SUCCESS] Import completed successfully'
    Write-Output ''
    Write-Log "Import completed successfully - $successCount script(s) executed" -Severity INFO
  }

  # Stop overall timing and export metrics
  if ($script:CollectMetrics) {
    if ($script:ImportStopwatch) {
      $script:ImportStopwatch.Stop()
      $script:Metrics.totalDurationSeconds = $script:ImportStopwatch.Elapsed.TotalSeconds
    }
    $script:Metrics.scriptsProcessed = $successCount + $failureCount + $skipCount
    $script:Metrics.scriptsSucceeded = $successCount
    $script:Metrics.scriptsFailed = $failureCount
    $script:Metrics.scriptsSkipped = $skipCount

    # Export metrics to tests folder or source path
    $metricsPath = if (Test-Path (Join-Path (Split-Path $PSScriptRoot) 'tests')) {
      Join-Path (Split-Path $PSScriptRoot) 'tests'
    }
    else {
      $SourcePath
    }
    Export-Metrics -OutputPath $metricsPath

    Write-Output ''
    Write-Output "Performance Metrics:"
    Write-Output "  Total duration:     $([math]::Round($script:Metrics.totalDurationSeconds, 2))s"
    Write-Output "  Connection time:    $([math]::Round($script:Metrics.connectionTimeSeconds, 2))s"
    Write-Output "  Script execution:   $([math]::Round($script:Metrics.scriptExecutionSeconds, 2))s"
    if ($script:Metrics.fkDisableSeconds -gt 0 -or $script:Metrics.fkEnableSeconds -gt 0) {
      Write-Output "  FK disable:         $([math]::Round($script:Metrics.fkDisableSeconds, 2))s"
      Write-Output "  FK re-enable:       $([math]::Round($script:Metrics.fkEnableSeconds, 2))s"
    }
    Write-Output "  Scripts processed:  $($script:Metrics.scriptsProcessed)"
    Write-Output ''
  }

  Write-Output '═══════════════════════════════════════════════'
  Write-Output ''

  if ($failureCount -eq 0) {
    exit 0
  }
  else {
    exit 1
  }

}
catch {
  Write-Error "[ERROR] Script error: $($_.ToString())"
  Write-Log "Script error: $($_.ToString())" -Severity ERROR
  exit 1
}

#endregion

