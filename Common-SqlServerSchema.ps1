#Requires -Version 7.0

<#
.SYNOPSIS
    Shared helper functions used by both Export-SqlServerSchema.ps1 and Import-SqlServerSchema.ps1.

.DESCRIPTION
    This file is dot-sourced by both main scripts at startup. It contains functions that are
    identical or near-identical between Export and Import, extracted to eliminate duplication.

    Functions provided:
      - Write-Log                    : Console + file logging with severity levels
      - Get-EscapedSqlIdentifier     : Escapes ] in SQL identifiers for bracketed notation
      - Invoke-WithRetry             : Exponential backoff retry for transient SQL errors
      - Read-ExportMetadata          : Reads _export_metadata.json from an export directory
      - ConvertFrom-AdoConnectionString : Parses ADO.NET connection strings
      - Resolve-EnvCredential        : Resolves credentials from environment variables
      - Resolve-ConfigFile           : Auto-discovers YAML config files

    This file has no param() block and no mandatory parameters, making it safe to dot-source.

.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema
    Issue: #66 - Extract shared functions into common helper library
#>

# ─────────────────────────────────────────────────────────────────────────────
# Write-Log
# ─────────────────────────────────────────────────────────────────────────────

function Write-Log {
  <#
    .SYNOPSIS
        Writes message to console and log file with timestamp.
    .DESCRIPTION
        Outputs the message to the console with color coding by severity level,
        and appends a timestamped entry to $script:LogFile if set and accessible.
    .PARAMETER Message
        The message text to log.
    .PARAMETER Level
        Severity level: INFO (default), SUCCESS, WARNING, or ERROR.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter()]
    [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
    [string]$Level = 'INFO'
  )

  $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
  $logEntry = "[$timestamp] [$Level] $Message"

  # Write to console
  switch ($Level) {
    'SUCCESS' { Write-Host $Message -ForegroundColor Green }
    'WARNING' { Write-Warning $Message }
    'ERROR' { Write-Host $Message -ForegroundColor Red }
    default { Write-Output $Message }
  }

  # Write to log file if available and parent directory exists
  if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
    try {
      Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
      # Silently fail if log write fails - don't interrupt main operation
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Get-EscapedSqlIdentifier
# ─────────────────────────────────────────────────────────────────────────────

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

# ─────────────────────────────────────────────────────────────────────────────
# Invoke-WithRetry
# ─────────────────────────────────────────────────────────────────────────────

function Invoke-WithRetry {
  <#
    .SYNOPSIS
        Executes a script block with retry logic for transient failures.
    .DESCRIPTION
        Implements exponential backoff retry strategy for handling transient errors
        like network timeouts, Azure SQL throttling, and connection pool issues.
    .PARAMETER ScriptBlock
        The script block to execute.
    .PARAMETER MaxAttempts
        Maximum number of attempts before giving up. Default: 3.
    .PARAMETER InitialDelaySeconds
        Seconds to wait before the first retry. Doubles on each subsequent retry. Default: 2.
    .PARAMETER OperationName
        Descriptive name for the operation, used in log messages. Default: 'Operation'.
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
        Write-Log "$OperationName failed (attempt $attempt): $errorType - $errorMessage" -Level WARNING

        Start-Sleep -Seconds $delay

        # Exponential backoff: double the delay for next attempt
        $delay = $delay * 2
      }
      else {
        # Non-transient error or final attempt - rethrow
        if ($isTransient) {
          Write-Error "[$OperationName] Failed after $MaxAttempts attempts: $errorMessage"
          Write-Log "$OperationName failed after $MaxAttempts attempts: $errorMessage" -Level ERROR
        }
        throw
      }
    }
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# Read-ExportMetadata
# ─────────────────────────────────────────────────────────────────────────────

function Read-ExportMetadata {
  <#
    .SYNOPSIS
        Reads and parses export metadata from a previous export.
    .DESCRIPTION
        Loads the _export_metadata.json file from a previous export directory
        and returns the parsed metadata object. Used for delta export validation,
        change detection, and import-time FileGroup sizing.
    .PARAMETER Path
        Path to the export directory containing _export_metadata.json.
    .OUTPUTS
        Hashtable containing the parsed metadata, or $null if not found.
    #>
  param(
    [Parameter(Mandatory)]
    [string]$Path
  )

  $metadataPath = Join-Path $Path '_export_metadata.json'
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
    Write-Warning "Failed to parse metadata file: $_"
    return $null
  }
}

# ─────────────────────────────────────────────────────────────────────────────
# ConvertFrom-AdoConnectionString
# ─────────────────────────────────────────────────────────────────────────────

function ConvertFrom-AdoConnectionString {
  <#
    .SYNOPSIS
        Parses an ADO.NET connection string into its component parts.
    .DESCRIPTION
        Uses System.Data.SqlClient.SqlConnectionStringBuilder to safely parse a SQL Server
        ADO.NET connection string. Recognises all standard SQL Server key aliases including
        alternate forms (Server/Data Source, Database/Initial Catalog, UID/User ID, etc.).
        Throws a descriptive error for malformed strings.
        Passwords are never emitted to verbose output or logs.
    .PARAMETER ConnectionString
        The ADO.NET connection string to parse.
    .OUTPUTS
        Hashtable: Server, Database, Username, Password (string, treat as secret),
        TrustServerCertificate (nullable bool), IntegratedSecurity (nullable bool).
  #>
  param(
    [string]$ConnectionString
  )

  $result = @{
    Server                 = $null
    Database               = $null
    Username               = $null
    Password               = $null
    TrustServerCertificate = $null
    IntegratedSecurity     = $null
  }

  if ([string]::IsNullOrWhiteSpace($ConnectionString)) { return $result }

  $builder = $null
  try {
    $builder = [System.Data.SqlClient.SqlConnectionStringBuilder]::new($ConnectionString)
  }
  catch {
    throw "Invalid connection string format: $($_.Exception.Message)"
  }

  if (-not [string]::IsNullOrWhiteSpace($builder.DataSource))     { $result.Server   = $builder.DataSource }
  if (-not [string]::IsNullOrWhiteSpace($builder.InitialCatalog)) { $result.Database  = $builder.InitialCatalog }
  if (-not [string]::IsNullOrWhiteSpace($builder.UserID))         { $result.Username  = $builder.UserID }
  if (-not [string]::IsNullOrWhiteSpace($builder.Password))       { $result.Password  = $builder.Password }

  # TrustServerCertificate: SqlConnectionStringBuilder always exposes this key with default false,
  # so check the original string text to distinguish explicit from default.
  if ($ConnectionString -imatch '(?:^|;)\s*TrustServerCertificate\s*=') {
    $result.TrustServerCertificate = $builder.TrustServerCertificate
  }

  # IntegratedSecurity: only set if true (non-default), using same text-based check for consistency
  if ($ConnectionString -imatch '(?:^|;)\s*(?:Integrated\s+Security|Trusted_Connection)\s*=') {
    $result.IntegratedSecurity = $builder.IntegratedSecurity
  }

  return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-EnvCredential
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-EnvCredential {
  <#
    .SYNOPSIS
        Resolves credential and connection parameters from environment variables.
    .DESCRIPTION
        Builds a PSCredential from environment variable names specified via *FromEnv parameters
        or config file connection section. Follows precedence (high to low):
          1. Explicit -Credential / -Server / -Database command-line parameters
          2. Individual *FromEnv CLI parameters (-ServerFromEnv, -UsernameFromEnv, -PasswordFromEnv)
          3. -ConnectionStringFromEnv CLI parameter (full ADO.NET connection string in env var)
          4. Config file connection: section equivalents
          5. Defaults (Windows auth, no overrides)
    .OUTPUTS
        Hashtable with resolved Server, Database, Credential, and TrustServerCertificate values.
  #>
  param(
    [string]$ServerParam,
    [string]$DatabaseParam,
    [pscredential]$CredentialParam,
    [string]$ServerFromEnvParam,
    [string]$UsernameFromEnvParam,
    [string]$PasswordFromEnvParam,
    [string]$ConnectionStringFromEnvParam,
    [bool]$TrustServerCertificateParam,
    [hashtable]$Config,
    [hashtable]$BoundParameters
  )

  $result = @{
    Server                 = $ServerParam
    Database               = $DatabaseParam
    Credential             = $CredentialParam
    TrustServerCertificate = $TrustServerCertificateParam
  }

  # --- Resolve TrustServerCertificate ---
  # CLI switch > config connection section > config root-level > connection string > default (false)
  $trustResolvedFromHigherPriority = $BoundParameters.ContainsKey('TrustServerCertificate')
  if (-not $trustResolvedFromHigherPriority) {
    $trustResolved = $false
    if ($Config -and $Config.ContainsKey('connection') -and $Config.connection -is [System.Collections.IDictionary]) {
      if ($Config.connection.ContainsKey('trustServerCertificate')) {
        $result.TrustServerCertificate = [bool]$Config.connection.trustServerCertificate
        $trustResolved = $true
        $trustResolvedFromHigherPriority = $true
      }
    }
    # Only fall back to root-level if connection section didn't specify it
    if (-not $trustResolved -and $Config -and $Config.ContainsKey('trustServerCertificate')) {
      $result.TrustServerCertificate = [bool]$Config.trustServerCertificate
      $trustResolvedFromHigherPriority = $true
    }
  }

  # --- Resolve Server from individual *FromEnv ---
  # CLI -Server > -ServerFromEnv > config connection.serverFromEnv
  $serverResolvedFromHigherPriority = $BoundParameters.ContainsKey('Server') -and -not [string]::IsNullOrWhiteSpace($ServerParam)
  if (-not $serverResolvedFromHigherPriority) {
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
      $serverResolvedFromHigherPriority = $true
      Write-Verbose "[ENV] Server resolved from environment variable '$serverEnvName'"
    }
  }

  # --- Resolve Credential from individual *FromEnv ---
  # CLI -Credential > *FromEnv params > config connection.*FromEnv
  $credResolvedFromHigherPriority = $BoundParameters.ContainsKey('Credential') -and $null -ne $CredentialParam
  if (-not $credResolvedFromHigherPriority) {
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
      if ([string]::IsNullOrWhiteSpace($passwordValue)) {
        throw "Environment variable '$passwordEnvName' (specified via PasswordFromEnv) is not set or is empty."
      }

      $securePassword = ConvertTo-SecureString $passwordValue -AsPlainText -Force
      $result.Credential = [System.Management.Automation.PSCredential]::new($usernameValue, $securePassword)
      $credResolvedFromHigherPriority = $true
      Write-Verbose "[ENV] Credential resolved from environment variables '$usernameEnvName' and '$passwordEnvName'"
    }
  }

  # --- Resolve from ConnectionStringFromEnv (lower priority than individual *FromEnv params) ---
  # CLI -ConnectionStringFromEnv > config connection.connectionStringFromEnv
  $connStrEnvName = $ConnectionStringFromEnvParam
  if (-not $connStrEnvName -and $Config -and $Config.ContainsKey('connection') -and $Config.connection -is [System.Collections.IDictionary]) {
    if ($Config.connection.ContainsKey('connectionStringFromEnv')) {
      $connStrEnvName = $Config.connection.connectionStringFromEnv
    }
  }

  if ($connStrEnvName) {
    $connStrValue = [System.Environment]::GetEnvironmentVariable($connStrEnvName)
    if ([string]::IsNullOrWhiteSpace($connStrValue)) {
      throw "Environment variable '$connStrEnvName' (specified via ConnectionStringFromEnv) is not set or is empty."
    }

    $parsed = ConvertFrom-AdoConnectionString -ConnectionString $connStrValue

    # Apply connection string values only for fields not already resolved by higher-priority sources
    if (-not $serverResolvedFromHigherPriority -and -not [string]::IsNullOrWhiteSpace($parsed.Server)) {
      $result.Server = $parsed.Server
      Write-Verbose "[ENV] Server resolved from connection string in environment variable '$connStrEnvName'"
    }

    $databaseResolvedFromHigherPriority = $BoundParameters.ContainsKey('Database') -and -not [string]::IsNullOrWhiteSpace($DatabaseParam)
    if (-not $databaseResolvedFromHigherPriority -and -not [string]::IsNullOrWhiteSpace($parsed.Database)) {
      $result.Database = $parsed.Database
      Write-Verbose "[ENV] Database resolved from connection string in environment variable '$connStrEnvName'"
    }

    if (-not $credResolvedFromHigherPriority -and -not [string]::IsNullOrWhiteSpace($parsed.Username) -and -not [string]::IsNullOrWhiteSpace($parsed.Password)) {
      $securePassword = ConvertTo-SecureString $parsed.Password -AsPlainText -Force
      $result.Credential = [System.Management.Automation.PSCredential]::new($parsed.Username, $securePassword)
      # NOTE: password is intentionally not logged
      Write-Verbose "[ENV] Credential resolved from connection string in environment variable '$connStrEnvName' (username: $($parsed.Username))"
    }

    if (-not $trustResolvedFromHigherPriority -and $null -ne $parsed.TrustServerCertificate) {
      $result.TrustServerCertificate = $parsed.TrustServerCertificate
    }
  }

  return $result
}

# ─────────────────────────────────────────────────────────────────────────────
# Resolve-ConfigFile
# ─────────────────────────────────────────────────────────────────────────────

function Resolve-ConfigFile {
  <#
    .SYNOPSIS
        Auto-discovers the config file when -ConfigFile is not provided.
    .DESCRIPTION
        Searches for well-known config file names in the script directory first,
        then the current working directory. Returns the first match found, or an
        empty string if no config file is discovered.
    .PARAMETER ScriptRoot
        The directory containing the script (typically $PSScriptRoot).
    .OUTPUTS
        The resolved absolute path to the config file, or empty string if not found.
    #>
  param(
    [string]$ScriptRoot
  )

  $wellKnownNames = @('export-import-config.yml', 'export-import-config.yaml')
  $searchPaths = @($ScriptRoot, $PWD.Path)

  foreach ($searchPath in $searchPaths) {
    if (-not $searchPath) { continue }
    foreach ($name in $wellKnownNames) {
      $candidate = Join-Path $searchPath $name
      if (Test-Path -LiteralPath $candidate -PathType Leaf) {
        return $candidate
      }
    }
  }

  return ''
}
