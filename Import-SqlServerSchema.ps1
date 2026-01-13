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
    Target SQL Server instance. Required parameter.
    Examples: 'localhost', 'server\SQLEXPRESS', '192.168.1.100', 'server.database.windows.net'

.PARAMETER Database
    Target database name. Will be created if -CreateDatabase is specified and it doesn't exist.
    Required parameter.

.PARAMETER SourcePath
    Path to the directory containing exported schema files (timestamped folder from Export-SqlServerSchema.ps1).
    Required parameter.

.PARAMETER Credential
    PSCredential object for SQL Server authentication. If not provided, uses integrated Windows authentication.

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

.NOTES
    Requires: SQL Server Management Objects (SMO), PowerShell 7.0+
    Optional: powershell-yaml module for YAML config file support
    Author: Zack Moore
    Supports: Windows, Linux, macOS
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'Target SQL Server instance')]
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
    [switch]$CollectMetrics
)

$ErrorActionPreference = if ($ContinueOnError) { 'Continue' } else { 'Stop' }
$script:LogFile = $null  # Will be set during import

# Performance metrics tracking (when -CollectMetrics is used)
$script:Metrics = @{
    timestamp = $null
    phase = 'phase1.5'
    server = $null
    database = $null
    sourcePath = $null
    importMode = $null
    totalDurationSeconds = 0.0
    initializationSeconds = 0.0
    connectionTimeSeconds = 0.0
    preliminaryChecksSeconds = 0.0
    scriptCollectionSeconds = 0.0
    scriptExecutionSeconds = 0.0
    fkDisableSeconds = 0.0
    fkEnableSeconds = 0.0
    scriptsProcessed = 0
    scriptsSucceeded = 0
    scriptsFailed = 0
    scriptsSkipped = 0
    dataScriptsCount = 0
    nonDataScriptsCount = 0
}
$script:ImportStopwatch = $null
$script:InitStopwatch = $null
$script:ConnectionStopwatch = $null
$script:PrelimStopwatch = $null
$script:ScriptCollectStopwatch = $null
$script:ScriptStopwatch = $null
$script:FKStopwatch = $null

#region Helper Functions

function Export-Metrics {
    <#
    .SYNOPSIS
        Exports collected metrics to a JSON file.
    #>
    param(
        [string]$OutputPath
    )
    
    if (-not $CollectMetrics) { return }
    
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
        'ERROR'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Output $Message }
    }
    
    # Write to log file if available
    if ($script:LogFile) {
        try {
            Add-Content -Path $script:LogFile -Value $logEntry -ErrorAction SilentlyContinue
        } catch {
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
        } catch {
            $isTransient = $false
            $errorMessage = $_.Exception.Message
            
            # Check for transient error patterns
            if ($errorMessage -match 'timeout|timed out|connection.*lost|connection.*closed') {
                $isTransient = $true
                $errorType = 'Network timeout'
            } elseif ($errorMessage -match '40501|40613|49918|10928|10929|40197|40540|40143') {
                # Azure SQL throttling error codes
                $isTransient = $true
                $errorType = 'Azure SQL throttling'
            } elseif ($errorMessage -match '1205') {
                # Deadlock victim
                $isTransient = $true
                $errorType = 'Deadlock'
            } elseif ($errorMessage -match 'pooling|connection pool') {
                $isTransient = $true
                $errorType = 'Connection pool issue'
            } elseif ($errorMessage -match '\b(53|233|64)\b') {
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
            } else {
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
        } else {
            # Fallback to direct assembly load
            Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
            Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available'
            return 'SMO'
        }
    } catch {
        Write-Output 'ℹ SMO not found, will attempt to use sqlcmd'
        
        try {
            $sqlcmdPath = Get-Command sqlcmd -ErrorAction Stop
            Write-Output "[SUCCESS] sqlcmd available at $($sqlcmdPath.Source)"
            return 'SQLCMD'
        } catch {
            throw "Neither SMO nor sqlcmd found. Install SQL Server Management Studio or sqlcmd utility."
        }
    }
}

function Get-TargetServerOS {
    <#
    .SYNOPSIS
        Detects the target SQL Server's operating system (Windows or Linux).
    .PARAMETER Connection
        Optional existing SMO Server connection to reuse. If not provided, uses sqlcmd.
    #>
    param(
        [string]$ServerName,
        [pscredential]$Cred,
        [hashtable]$Config,
        [Microsoft.SqlServer.Management.Smo.Server]$Connection
    )
    
    $query = "SELECT CASE WHEN host_platform = 'Windows' THEN 'Windows' ELSE 'Linux' END AS OS FROM sys.dm_os_host_info"
    
    try {
        # If we have an open SMO connection, use it
        if ($Connection -and $Connection.ConnectionContext.IsOpen) {
            $result = $Connection.ConnectionContext.ExecuteScalar($query)
            Write-Verbose "Target server OS detected via SMO: $result"
            return $result
        }
        
        # Fallback to sqlcmd if no connection provided
        $sqlcmdParams = @("-S", $ServerName, "-Q", $query, "-h", "-1", "-W")
        
        if ($Cred) {
            $sqlcmdParams += @("-U", $Cred.UserName, "-P", $Cred.GetNetworkCredential().Password)
        }
        
        # Add -C flag if trustServerCertificate is enabled in config
        if ($Config -and $Config.ContainsKey('trustServerCertificate') -and $Config.trustServerCertificate) {
            $sqlcmdParams += "-C"
        }
        
        $result = sqlcmd @sqlcmdParams
        
        $os = ($result | Select-String -Pattern '(Windows|Linux)').Matches[0].Value
        Write-Verbose "Target server OS detected: $os"
        return $os
    } catch {
        Write-Verbose "Could not detect target OS, assuming Windows: $_"
        return 'Windows'
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
        } else {
            $ownConnection = $true
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
            $server.ConnectionContext.ConnectTimeout = $Timeout
            
            # Apply TrustServerCertificate from config if specified
            if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
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
    } catch {
        if ($_.Exception.Message -match 'certificate|SSL|TLS') {
            Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server: $_

This usually occurs with SQL Server 2022+ using self-signed certificates.

SOLUTION: Add to your config file:
  trustServerCertificate: true

Or create a config file with:
  trustServerCertificate: true
  
For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
        } else {
            Write-Error "[ERROR] Connection failed: $_"
        }
        return $false
    } finally {
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
        } else {
            $ownConnection = $true
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
            if ($Cred) {
                $server.ConnectionContext.LoginSecure = $false
                $server.ConnectionContext.Login = $Cred.UserName
                $server.ConnectionContext.SecurePassword = $Cred.Password
            }
            
            # Apply TrustServerCertificate from config if specified
            if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
                $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
            }
            
            $server.ConnectionContext.ConnectTimeout = $Timeout
            $server.ConnectionContext.Connect()
        }
        $exists = $null -ne $server.Databases[$DatabaseName]
        return $exists
    } catch {
        Write-Error "[ERROR] Error checking database: $_"
        return $false
    } finally {
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
        } else {
            $ownConnection = $true
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
            if ($Cred) {
                $server.ConnectionContext.LoginSecure = $false
                $server.ConnectionContext.Login = $Cred.UserName
                $server.ConnectionContext.SecurePassword = $Cred.Password
            }
            
            # Apply TrustServerCertificate from config if specified
            if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
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
    } catch {
        Write-Error "[ERROR] Error checking schema: $_"
        return $false
    } finally {
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
        
        # Apply TrustServerCertificate from config if specified
        if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
            $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
        }
        
        $server.ConnectionContext.ConnectTimeout = $Timeout
        $server.ConnectionContext.Connect()
        
        $db = [Microsoft.SqlServer.Management.Smo.Database]::new($server, $DatabaseName)
        $db.Create()
        Write-Host "[SUCCESS] Database $DatabaseName created" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "[ERROR] Failed to create database: $_"
        return $false
    } finally {
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
    
    # Apply TrustServerCertificate from config if specified
    if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
        $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
    }
    
    try {
        $server.ConnectionContext.Connect()
        return $server
    } catch {
        if ($_.Exception.Message -match 'certificate|SSL|TLS') {
            Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server: $_

This usually occurs with SQL Server 2022+ using self-signed certificates.

SOLUTION: Add to your config file:
  trustServerCertificate: true

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
    } elseif ($FilePath) {
        if (-not (Test-Path $FilePath)) {
            Write-Warning "Script file not found: $FilePath"
            return $false
        }
        $scriptName = Split-Path -Leaf $FilePath
        $sql = Get-Content $FilePath -Raw
    } else {
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
        
        # Replace ALTER DATABASE CURRENT with actual database name
        # CURRENT keyword doesn't work with SMO ExecuteNonQuery
        $sql = $sql -replace '\bALTER\s+DATABASE\s+CURRENT\b', "ALTER DATABASE [$DatabaseName]"
        
        # For FileGroups scripts, ensure logical file names are unique by prefixing with database name
        # This prevents conflicts when multiple databases on same server use similar schema
        # Pattern: NAME = N'OriginalName' (but NOT FILENAME = ...)
        # Use negative lookbehind to ensure we're not matching FILENAME
        if ($scriptName -match '(?i)filegroup') {
            $sql = $sql -replace "(?<!FILE)NAME\s*=\s*N'([^']+)'", "NAME = N'${DatabaseName}_`$1'"
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
        } else {
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
            if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
                $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
            }
            
            try {
                $server.ConnectionContext.Connect()
            } catch {
                if ($_.Exception.Message -match 'certificate|SSL|TLS') {
                    Write-Error @"
[ERROR] SSL/Certificate error connecting to SQL Server for script execution: $_

This usually occurs with SQL Server 2022+ using self-signed certificates.

SOLUTION: Add to your config file:
  trustServerCertificate: true

Failed script: $scriptName
For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
                }
                throw
            }
        }
        
        $server.ConnectionContext.StatementTimeout = $Timeout
        
        # Split by GO statements (batch separator)
        # GO must be on its own line (with optional whitespace)
        $batches = $sql -split '(?m)^\s*GO\s*$' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        
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
        return $true
    } catch {
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
        
        Write-Error "  [ERROR] Failed: $scriptName`n$errorMessage"
        return -1
    }
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
        } else {
            # Simplified config or no config - use Dev defaults
            @{
                includeFileGroups = $false
                includeConfigurations = $false
                includeDatabaseScopedCredentials = $false
                includeExternalData = $false
                enableSecurityPolicies = $false
            }
        }
    } else {
        # Prod mode
        if ($Config.import -and $Config.import.productionMode) {
            # Full config format with nested mode settings
            $Config.import.productionMode
        } else {
            # Simplified config or no config - use Prod defaults
            @{
                includeFileGroups = $true
                includeConfigurations = $true
                includeDatabaseScopedCredentials = $false
                includeExternalData = $true
                enableSecurityPolicies = $true
            }
        }
    }
    
    # Build ordered directory list based on mode
    $orderedDirs = @()
    
    # FileGroups - skip in Dev mode unless explicitly enabled
    if ($modeSettings.includeFileGroups) {
        $orderedDirs += '00_FileGroups'
    }
    
    # Database Configuration - skip in Dev mode unless explicitly enabled
    if ($modeSettings.includeConfigurations) {
        $orderedDirs += '01_DatabaseConfiguration'
    }
    
    # Core schema objects - always included
    $orderedDirs += @(
        '02_Schemas',
        '03_Sequences',
        '04_PartitionFunctions',
        '05_PartitionSchemes',
        '06_Types',
        '07_XmlSchemaCollections',
        '08_Tables_PrimaryKey',
        '09_Tables_ForeignKeys',
        '10_Indexes',
        '11_Defaults',
        '12_Rules',
        '13_Programmability',
        '14_Synonyms',
        '15_FullTextSearch'
    )
    
    # External Data - skip in Dev mode unless explicitly enabled
    if ($modeSettings.includeExternalData) {
        $orderedDirs += '16_ExternalData'
    }
    
    # Search Property Lists and Plan Guides - always included (harmless)
    $orderedDirs += @(
        '17_SearchPropertyLists',
        '18_PlanGuides'
    )
    
    # Security - always include keys/certs/roles/users
    $orderedDirs += '19_Security'
    
    # Data - only if requested
    Write-Verbose "Get-ScriptFiles: IncludeData parameter = $IncludeData"
    if ($IncludeData) {
        $orderedDirs += '20_Data'
        Write-Verbose "Added 20_Data to ordered directories"
    } else {
        Write-Verbose "Skipping 20_Data (IncludeData=$IncludeData)"
    }
    
    $scripts = @()
    $skippedFolders = @()
    
    foreach ($dir in $orderedDirs) {
        $fullPath = Join-Path $Path $dir
        if (Test-Path $fullPath) {
            # Special handling for Security folder - may need to skip RLS policies
            if ($dir -eq '19_Security' -and -not $modeSettings.enableSecurityPolicies) {
                # Get all security scripts except SecurityPolicies
                $securityScripts = Get-ChildItem -Path $fullPath -Filter '*.sql' -Recurse | 
                    Where-Object { $_.Name -notmatch 'SecurityPolicies' } |
                    Sort-Object FullName
                $scripts += @($securityScripts)
                
                if ((Get-ChildItem -Path $fullPath -Filter '*SecurityPolicies.sql' -ErrorAction SilentlyContinue).Count -gt 0) {
                    Write-Output "  [INFO] Skipping Row-Level Security policies (disabled in $Mode mode)"
                }
            } else {
                $scripts += @(Get-ChildItem -Path $fullPath -Filter '*.sql' -Recurse | 
                    Sort-Object FullName)
            }
        }
    }
    
    # Track skipped folders for reporting
    $allPossibleDirs = @('00_FileGroups', '01_DatabaseConfiguration', '16_ExternalData', '20_Data')
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
        Scripts = $scripts
        SkippedFolders = $skippedFolders
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
            } else {
                throw "Configuration file contains multiple YAML documents. Only single document configs are supported."
            }
        } else {
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
        
    } catch {
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
    
    Write-Host ""
    Write-Host "IMPORT STRATEGY ($Mode Mode)" -ForegroundColor Yellow
    Write-Host "$(('-' * (17 + $Mode.Length)))" -ForegroundColor Yellow
    
    # Get mode-specific settings
    # Support both simplified config (no import.mode structure) and full config (nested)
    $modeSettings = if ($Mode -eq 'Dev') {
        if ($Config.import -and $Config.import.developerMode) {
            # Full config format with nested mode settings
            $Config.import.developerMode
        } else {
            # Simplified config or no config - use Dev defaults
            @{
                includeFileGroups = $false
                includeConfigurations = $false
                includeDatabaseScopedCredentials = $false
                includeExternalData = $false
                enableSecurityPolicies = $false
            }
        }
    } else {
        # Prod mode
        if ($Config.import -and $Config.import.productionMode) {
            # Full config format with nested mode settings
            $Config.import.productionMode
        } else {
            # Simplified config or no config - use Prod defaults
            @{
                includeFileGroups = $true
                includeConfigurations = $true
                includeDatabaseScopedCredentials = $false
                includeExternalData = $true
                enableSecurityPolicies = $true
            }
        }
    }
    
    # Display mode-specific settings
    if ($modeSettings.includeFileGroups) {
        Write-Host "[ENABLED] FileGroups" -ForegroundColor Green
    } else {
        Write-Host "[SKIPPED] FileGroups (environment-specific)" -ForegroundColor Yellow
    }
    
    if ($modeSettings.includeConfigurations) {
        Write-Host "[ENABLED] Database Scoped Configurations" -ForegroundColor Green
    } else {
        Write-Host "[SKIPPED] Database Scoped Configurations (hardware-specific)" -ForegroundColor Yellow
    }
    
    if ($modeSettings.includeDatabaseScopedCredentials) {
        Write-Host "[ENABLED] Database Scoped Credentials" -ForegroundColor Green
    } else {
        Write-Host "[SKIPPED] Database Scoped Credentials (always - secrets required)" -ForegroundColor Gray
    }
    
    if ($modeSettings.includeExternalData) {
        Write-Host "[ENABLED] External Data Sources" -ForegroundColor Green
    } else {
        Write-Host "[SKIPPED] External Data Sources (environment-specific)" -ForegroundColor Yellow
    }
    
    if ($modeSettings.enableSecurityPolicies) {
        Write-Host "[ENABLED] Row-Level Security Policies" -ForegroundColor Green
    } else {
        Write-Host "[DISABLED] Row-Level Security Policies (dev convenience)" -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Starting import..." -ForegroundColor Cyan
    Write-Host ""
}

#endregion

#region Main Script

try {
    # Start overall timing if collecting metrics
    if ($CollectMetrics) {
        $script:ImportStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        $script:InitStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    
    # Load configuration if provided
    $config = @{ 
        import = @{ 
            defaultMode = 'Dev'
            developerMode = @{
                includeFileGroups = $false
                includeConfigurations = $false
                includeDatabaseScopedCredentials = $false
                includeExternalData = $false
                enableSecurityPolicies = $false
            }
            productionMode = @{
                includeFileGroups = $true
                includeConfigurations = $true
                includeDatabaseScopedCredentials = $false
                includeExternalData = $true
                enableSecurityPolicies = $true
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
            
            # Override ImportMode if specified in config
            if ($configImportMode -and $ImportMode -eq 'Dev') {
                $ImportMode = $configImportMode
                Write-Output "[INFO] Import mode set from config file: $ImportMode"
            }
            
            # Override IncludeData if specified in config
            # Support both simplified config (includeData at root) and full config (nested mode settings)
            Write-Verbose "Config includeData value: $($config.includeData), Parameter IncludeData: $IncludeData"
            if ($config.includeData -and -not $IncludeData) {
                $IncludeData = $config.includeData
                Write-Output "[INFO] Data import enabled from config file"
            } elseif ($config.import) {
                $modeSettings = if ($ImportMode -eq 'Dev') { $config.import.developerMode } else { $config.import.productionMode }
                if ($modeSettings.includeData -and -not $IncludeData) {
                    $IncludeData = $modeSettings.includeData
                    Write-Output "[INFO] Data import enabled from config file"
                }
            }
        } else {
            Write-Warning "Config file not found: $ConfigFile"
            Write-Warning "Continuing with default settings..."
        }
    }
    
    # Apply timeout settings from config or use defaults
    # Parameters override config values (if non-zero)
    $effectiveConnectionTimeout = if ($ConnectionTimeout -gt 0) { 
        $ConnectionTimeout 
    } elseif ($config -and $config.ContainsKey('connectionTimeout')) { 
        $config.connectionTimeout 
    } else { 
        30 
    }
    
    $effectiveCommandTimeout = if ($CommandTimeout -gt 0) { 
        $CommandTimeout 
    } elseif ($config -and $config.ContainsKey('commandTimeout')) { 
        $config.commandTimeout 
    } else { 
        300 
    }
    
    $effectiveMaxRetries = if ($MaxRetries -gt 0) {
        $MaxRetries
    } elseif ($config -and $config.ContainsKey('maxRetries')) {
        $config.maxRetries
    } else {
        3
    }
    
    $effectiveRetryDelay = if ($RetryDelaySeconds -gt 0) {
        $RetryDelaySeconds
    } elseif ($config -and $config.ContainsKey('retryDelaySeconds')) {
        $config.retryDelaySeconds
    } else {
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
    if ($CollectMetrics) {
        $script:InitStopwatch.Stop()
        $script:Metrics.initializationSeconds = $script:InitStopwatch.Elapsed.TotalSeconds
        $script:PrelimStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
        Write-Verbose "[TIMING] Preliminary checks starting..."
    }
    
    # Create shared connection for preliminary checks and script execution
    # This eliminates connection overhead from multiple check functions
    # Note: Connect to 'master' first if -CreateDatabase is used (target DB might not exist yet)
    if ($CollectMetrics) { 
        $script:ConnectionStopwatch = [System.Diagnostics.Stopwatch]::StartNew() 
        Write-Verbose "[TIMING] Creating shared connection..."
    }
    try {
        # Connect to master first for preliminary checks - reconnect to target DB later if needed
        $initialDb = if ($CreateDatabase) { 'master' } else { $Database }
        $script:SharedConnection = New-SqlServerConnection -ServerName $Server -DatabaseName $initialDb -Cred $Credential -Config $config -Timeout $effectiveCommandTimeout
    } catch {
        Write-Error "[ERROR] Failed to create connection: $_"
        Write-Log "Failed to create connection to $Server" -Severity ERROR
        exit 1
    }
    if ($CollectMetrics) {
        $script:ConnectionStopwatch.Stop()
        $script:Metrics.connectionTimeSeconds = $script:ConnectionStopwatch.Elapsed.TotalSeconds
        Write-Verbose "[TIMING] Shared connection created in $([math]::Round($script:ConnectionStopwatch.Elapsed.TotalSeconds, 3))s"
    }
    
    # Test connection to server (reuse shared connection)
    if ($CollectMetrics) { Write-Verbose "[TIMING] Starting Test-DatabaseConnection..." }
    $testConnSw = [System.Diagnostics.Stopwatch]::StartNew()
    if (-not (Test-DatabaseConnection -ServerName $Server -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection)) {
        Write-Log "Connection test failed to $Server" -Severity ERROR
        exit 1
    }
    $testConnSw.Stop()
    if ($CollectMetrics) { Write-Verbose "[TIMING] Test-DatabaseConnection completed in $([math]::Round($testConnSw.Elapsed.TotalSeconds, 3))s" }
    Write-Log "Connection test successful to $Server" -Severity INFO
    Write-Output ''
    
    # Check if database exists (reuse shared connection)
    if ($CollectMetrics) { Write-Verbose "[TIMING] Starting Test-DatabaseExists..." }
    $testDbSw = [System.Diagnostics.Stopwatch]::StartNew()
    $dbExists = Test-DatabaseExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection
    $testDbSw.Stop()
    if ($CollectMetrics) { Write-Verbose "[TIMING] Test-DatabaseExists completed in $([math]::Round($testDbSw.Elapsed.TotalSeconds, 3))s" }
    
    if (-not $dbExists) {
        if ($CreateDatabase) {
            if (-not (New-Database -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout)) {
                exit 1
            }
            # Reconnect shared connection to the new database
            Write-Verbose "[TIMING] Reconnecting to target database..."
            $script:SharedConnection.ConnectionContext.Disconnect()
            $script:SharedConnection = New-SqlServerConnection -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveCommandTimeout
        } else {
            Write-Error "Database '$Database' does not exist. Use -CreateDatabase to create it."
            exit 1
        }
    } else {
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
    if ($CollectMetrics) { Write-Verbose "[TIMING] Starting Test-SchemaExists..." }
    $testSchemaSw = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-SchemaExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout -Connection $script:SharedConnection) {
        if (-not $Force) {
            Write-Output "[INFO[ Database $Database already contains schema objects."
            Write-Output "Use -Force to proceed with redeployment."
            exit 0
        }
        Write-Output '[INFO[ Proceeding with redeployment due to -Force flag'
    }
    $testSchemaSw.Stop()
    if ($CollectMetrics) { Write-Verbose "[TIMING] Test-SchemaExists completed in $([math]::Round($testSchemaSw.Elapsed.TotalSeconds, 3))s" }
    Write-Output ''
    
    if ($CollectMetrics) { Write-Verbose "[TIMING] Preliminary checks total so far: $([math]::Round($script:PrelimStopwatch.Elapsed.TotalSeconds, 3))s" }
    
    # End preliminary checks timing, start script collection timing
    if ($CollectMetrics) {
        $script:PrelimStopwatch.Stop()
        $script:Metrics.preliminaryChecksSeconds = $script:PrelimStopwatch.Elapsed.TotalSeconds
        $script:ScriptCollectStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    }
    
    # Get scripts in order
    Write-Output "Collecting scripts from: $(Split-Path -Leaf $SourcePath)"
    $scriptInfo = Get-ScriptFiles -Path $SourcePath -IncludeData:$IncludeData -Mode $ImportMode -Config $config
    $scripts = $scriptInfo.Scripts
    $skippedFolders = $scriptInfo.SkippedFolders
    
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
    if ($CollectMetrics) {
        $script:ScriptCollectStopwatch.Stop()
        $script:Metrics.scriptCollectionSeconds = $script:ScriptCollectStopwatch.Elapsed.TotalSeconds
    }
    
    # Build SQLCMD variables from config (for FileGroup path mappings, etc.)
    $sqlCmdVars = @{}
    if ($config) {
        # Support both simplified config (fileGroupPathMapping at root) and full config (nested)
        $modeConfig = $null
        if ($config.fileGroupPathMapping) {
            # Simplified config format (root-level fileGroupPathMapping)
            $modeConfig = $config
        } elseif ($config.import) {
            # Full config format (nested under import.productionMode or import.developerMode)
            $modeConfig = if ($ImportMode -eq 'Prod') { $config.import.productionMode } else { $config.import.developerMode }
        }
        
        if ($modeConfig -and $modeConfig.fileGroupPathMapping) {
            # First pass: read FileGroups SQL to extract file names
            $fileGroupScript = Join-Path $SourcePath '00_FileGroups' '001_FileGroups.sql'
            $fileGroupFiles = @{}  # Map: FileGroup -> [list of file names]
            
            if (Test-Path $fileGroupScript) {
                # Parse FileGroup names and file names from comments
                $currentFG = $null
                foreach ($line in (Get-Content $fileGroupScript)) {
                    if ($line -match '-- FileGroup: (.+)') {
                        $currentFG = $matches[1]
                        $fileGroupFiles[$currentFG] = @()
                    }
                    elseif ($line -match '-- File: (.+)' -and $currentFG) {
                        $fileGroupFiles[$currentFG] += $matches[1]
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
                # Include database name in filename to avoid conflicts with other databases
                if ($fileGroupFiles.ContainsKey($fg)) {
                    foreach ($fileName in $fileGroupFiles[$fg]) {
                        $fileVarName = "${fg}_PATH_FILE"
                        # Use database name + original file name for uniqueness
                        $uniqueFileName = "${Database}_${fileName}"
                        $fullPath = "${basePath}${pathSeparator}${uniqueFileName}.ndf"
                        $sqlCmdVars[$fileVarName] = $fullPath
                        Write-Verbose "SQLCMD Variable: `$($fileVarName) = $fullPath"
                    }
                }
            }
        }
    }
    
    # Report skipped folders if any
    if ($skippedFolders.Count -gt 0) {
        Write-Output "[INFO] Skipped $($skippedFolders.Count) folder(s) due to $ImportMode mode settings:"
        foreach ($folder in $skippedFolders) {
            $reason = switch ($folder) {
                '00_FileGroups' { 'FileGroups (environment-specific)' }
                '01_DatabaseConfiguration' { 'Database Scoped Configurations (environment-specific)' }
                '16_ExternalData' { 'External Data Sources (environment-specific)' }
                '20_Data' { 'Data not requested' }
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
    if ($CollectMetrics) {
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
    
    # Process non-data scripts first
    foreach ($script in $nonDataScripts) {
        $result = Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "Script: $($script.Name)" -ScriptBlock {
            Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
                -DatabaseName $Database -Cred $Credential -Timeout $effectiveCommandTimeout -Show:$ShowSQL `
                -SqlCmdVariables $sqlCmdVars -Config $config -Connection $script:SharedConnection
        }
        
        if ($result -eq $true) {
            $successCount++
        } elseif ($result -eq -1) {
            $failureCount++
            if (-not $ContinueOnError) {
                break
            }
        } else {
            $skipCount++
        }
    }
    
    # If we have data scripts and no failures so far, handle them with FK constraints disabled
    Write-Verbose "FK disable check: dataScripts.Count=$($dataScripts.Count), failureCount=$failureCount"
    if ($dataScripts.Count -gt 0 -and $failureCount -eq 0) {
        Write-Output ''
        Write-Output 'Preparing for data import...'
        Write-Verbose "Attempting to disable foreign key constraints..."
        
        # Disable all foreign key constraints  
        # Get list of FKs and disable them individually
        $smServer = $null
        if ($CollectMetrics) { $script:FKStopwatch = [System.Diagnostics.Stopwatch]::StartNew() }
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
            
            # Apply TrustServerCertificate from config if specified
            if ($config -and $config.ContainsKey('trustServerCertificate')) {
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
            } else {
                Write-Output '[INFO] No foreign key constraints to disable'
            }
        } catch {
            Write-Warning "[WARNING] Could not disable foreign keys: $_"
            Write-Warning '  Data import may fail if files are not in dependency order'
            Write-Warning '  Attempting to continue with data import...'
        } finally {
            if ($smServer -and $smServer.ConnectionContext.IsOpen) {
                $smServer.ConnectionContext.Disconnect()
            }
            if ($CollectMetrics -and $script:FKStopwatch) {
                $script:FKStopwatch.Stop()
                $script:Metrics.fkDisableSeconds = $script:FKStopwatch.Elapsed.TotalSeconds
            }
        }
        
        Write-Output ''
        Write-Output 'Importing data files...'
        
        # Process data scripts
        foreach ($script in $dataScripts) {
            $result = Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "Data Script: $($script.Name)" -ScriptBlock {
                Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
                    -DatabaseName $Database -Cred $Credential -Timeout $effectiveCommandTimeout -Show:$ShowSQL `
                    -SqlCmdVariables $sqlCmdVars -Config $config -Connection $script:SharedConnection
            }
            
            if ($result -eq $true) {
                $successCount++
            } elseif ($result -eq -1) {
                $failureCount++
                if (-not $ContinueOnError) {
                    break
                }
            } else {
                $skipCount++
            }
        }
        
        # Re-enable all foreign key constraints and validate data
        $smServer = $null
        if ($CollectMetrics) { $script:FKStopwatch = [System.Diagnostics.Stopwatch]::StartNew() }
        try {
            $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
            if ($Credential) {
                $smServer.ConnectionContext.set_LoginSecure($false)
                $smServer.ConnectionContext.set_Login($Credential.UserName)
                $smServer.ConnectionContext.set_SecurePassword($Credential.Password)
            }
            $smServer.ConnectionContext.ConnectTimeout = $effectiveConnectionTimeout
            $smServer.ConnectionContext.DatabaseName = $Database
            
            # Apply TrustServerCertificate from config if specified
            if ($config -and $config.ContainsKey('trustServerCertificate')) {
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
                        } catch {
                            Write-Error "  [ERROR] Failed to re-enable FK $($fk.Name) on $($table.Schema).$($table.Name): $_"
                            $errorCount++
                        }
                    }
                }
            }
            
            if ($errorCount -gt 0) {
                Write-Error "[ERROR] Foreign key constraint validation failed ($errorCount errors) - data may violate referential integrity"
                $failureCount++
            } elseif ($fkCount -gt 0) {
                Write-Output "[SUCCESS] Re-enabled and validated $fkCount foreign key constraint(s)"
            } else {
                Write-Output 'ℹ No foreign key constraints to re-enable'
            }
        } catch {
            Write-Error "[ERROR] Error re-enabling foreign keys: $_"
            $failureCount++
        } finally {
            if ($smServer -and $smServer.ConnectionContext.IsOpen) {
                $smServer.ConnectionContext.Disconnect()
            }
            if ($CollectMetrics -and $script:FKStopwatch) {
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
    if ($CollectMetrics -and $script:ScriptStopwatch) {
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
                '01_DatabaseConfiguration' { 'Database Configurations (hardware-specific, skipped in Dev mode)' }
                '16_ExternalData' { 'External Data Sources (environment-specific, skipped in Dev mode)' }
                '20_Data' { 'Data not requested via -IncludeData flag' }
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
    $sourceDbConfigPath = Join-Path $SourcePath '01_DatabaseConfiguration'
    if ((Test-Path $sourceDbConfigPath) -and ('01_DatabaseConfiguration' -in $skippedFolders)) {
        $manualActions += "[INFO] Database Scoped Configurations were exported but not imported (Dev mode)"
        $manualActions += "  Use -ImportMode Prod to import configurations (review settings first)"
    }
    
    # Check if External Data was in source but skipped
    $sourceExtDataPath = Join-Path $SourcePath '16_ExternalData'
    if ((Test-Path $sourceExtDataPath) -and ('16_ExternalData' -in $skippedFolders)) {
        $manualActions += "[INFO] External Data Sources were exported but not imported (Dev mode)"
        $manualActions += "  Use -ImportMode Prod to import external data (review connection strings first)"
    }
    
    # Check for Database Scoped Credentials (never imported, always manual)
    $sourceCredsPath = Join-Path $SourcePath '01_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
    if (Test-Path $sourceCredsPath) {
        $credsContent = Get-Content $sourceCredsPath -Raw
        if ($credsContent -match 'CREATE DATABASE SCOPED CREDENTIAL') {
            $manualActions += "[ACTION REQUIRED] Database Scoped Credentials"
            $manualActions += "  Location: Source\01_DatabaseConfiguration\002_DatabaseScopedCredentials.sql"
            $manualActions += "  Action: Manually create credentials with appropriate secrets on target server"
            $manualActions += "  Note: Credentials cannot be scripted with secrets - must be manually configured"
        }
    }
    
    # Check for RLS policies
    $sourceRlsPath = Join-Path $SourcePath '19_Security' '008_SecurityPolicies.sql'
    if (Test-Path $sourceRlsPath) {
        $rlsContent = Get-Content $sourceRlsPath -Raw
        if ($rlsContent -match 'CREATE SECURITY POLICY') {
            $modeSettings = if ($ImportMode -eq 'Dev') {
                if ($config.import -and $config.import.developerMode) {
                    $config.import.developerMode
                } else {
                    @{ enableSecurityPolicies = $false }
                }
            } else {
                @{ enableSecurityPolicies = $true }
            }
            
            if (-not $modeSettings.enableSecurityPolicies) {
                $manualActions += "[INFO] Row-Level Security Policies were exported but not imported ($ImportMode mode)"
                $manualActions += "  RLS policies are disabled in Dev mode by default to simplify testing"
                $manualActions += "  Use -ImportMode Prod or configure enableSecurityPolicies = true in config file"
            }
        }
    }
    
    if ($manualActions.Count -gt 0) {
        Write-Output "Manual actions and information:"
        Write-Output ''
        $manualActions | ForEach-Object { Write-Output $_ }
        Write-Output ''
    }
    
    if ($failureCount -gt 0) {
        Write-Output '[ERROR] Import completed with errors - review output above'
        Write-Output ''
        Write-Log "Import completed with $failureCount error(s)" -Severity ERROR
    } else {
        Write-Output '[SUCCESS] Import completed successfully'
        Write-Output ''
        Write-Log "Import completed successfully - $successCount script(s) executed" -Severity INFO
    }
    
    # Stop overall timing and export metrics
    if ($CollectMetrics) {
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
        } else {
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
    } else {
        exit 1
    }
    
} catch {
    Write-Error "[ERROR] Script error: $_"
    Write-Log "Script error: $_" -Severity ERROR
    exit 1
}

#endregion
