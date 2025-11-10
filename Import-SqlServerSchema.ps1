#Requires -Version 7.0

<#
.NOTES
    Version: 1.1.0
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
    
    [Parameter(HelpMessage = 'Command timeout in seconds')]
    [int]$CommandTimeout = 300,
    
    [Parameter(HelpMessage = 'Show SQL scripts during execution')]
    [switch]$ShowSQL,
    
    [Parameter(HelpMessage = 'Import mode: Dev (skip infrastructure) or Prod (import everything)')]
    [ValidateSet('Dev', 'Prod')]
    [string]$ImportMode = 'Dev',
    
    [Parameter(HelpMessage = 'Path to YAML configuration file')]
    [string]$ConfigFile
)

$ErrorActionPreference = if ($ContinueOnError) { 'Continue' } else { 'Stop' }

#region Helper Functions

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
    #>
    param(
        [string]$ServerName,
        [pscredential]$Cred,
        [hashtable]$Config
    )
    
    try {
        $query = "SELECT CASE WHEN host_platform = 'Windows' THEN 'Windows' ELSE 'Linux' END AS OS FROM sys.dm_os_host_info"
        
        # Build sqlcmd parameters
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
    #>
    param(
        [string]$ServerName,
        [pscredential]$Cred,
        [hashtable]$Config
    )
    
    Write-Host "Testing connection to $ServerName..."
    
    try {
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        $server.ConnectionContext.ConnectTimeout = 10
        
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
        $server.ConnectionContext.Disconnect()
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
    }
}

function Test-DatabaseExists {
    <#
    .SYNOPSIS
        Checks if target database exists.
    #>
    param(
        [string]$ServerName,
        [string]$DatabaseName,
        [pscredential]$Cred,
        [hashtable]$Config
    )
    
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
        
        $server.ConnectionContext.Connect()
        $exists = $null -ne $server.Databases[$DatabaseName]
        $server.ConnectionContext.Disconnect()
        return $exists
    } catch {
        Write-Error "[ERROR] Error checking database: $_"
        return $false
    }
}

function Test-SchemaExists {
    <#
    .SYNOPSIS
        Checks if schema already exists in target database.
    #>
    param(
        [string]$ServerName,
        [string]$DatabaseName,
        [pscredential]$Cred,
        [hashtable]$Config
    )
    
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
        
        $server.ConnectionContext.Connect()
        
        $db = $server.Databases[$DatabaseName]
        if ($null -eq $db) {
            $server.ConnectionContext.Disconnect()
            return $false
        }
        
        # Check if any user objects exist (excluding system objects)
        $userTables = @($db.Tables | Where-Object { -not $_.IsSystemObject })
        $userViews = @($db.Views | Where-Object { -not $_.IsSystemObject })
        $userProcs = @($db.StoredProcedures | Where-Object { -not $_.IsSystemObject })
        $hasObjects = ($userTables.Count -gt 0) -or ($userViews.Count -gt 0) -or ($userProcs.Count -gt 0)
        $server.ConnectionContext.Disconnect()
        return $hasObjects
    } catch {
        Write-Error "[ERROR] Error checking schema: $_"
        return $false
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
        [hashtable]$Config
    )
    
    Write-Host "Creating database $DatabaseName..."
    
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
        
        $server.ConnectionContext.Connect()
        
        $db = [Microsoft.SqlServer.Management.Smo.Database]::new($server, $DatabaseName)
        $db.Create()
        $server.ConnectionContext.Disconnect()
        Write-Host "[SUCCESS] Database $DatabaseName created" -ForegroundColor Green
        return $true
    } catch {
        Write-Error "[ERROR] Failed to create database: $_"
        return $false
    }
}

function Invoke-SqlScript {
    <#
    .SYNOPSIS
        Executes a SQL script file or content against the target database.
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
        [hashtable]$Config
    )
    
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
        
        $server.ConnectionContext.Disconnect()
        
        Write-Output "  [SUCCESS] Applied: $scriptName"
        return $true
    } catch {
        $errorMessage = $_.Exception.Message
        
        # Try to get the actual SQL Server error
        if ($_.Exception.InnerException) {
            $innerMsg = $_.Exception.InnerException.Message
            $errorMessage += "`n      Inner Exception: $innerMsg"
            
            # If it's a SQL Server exception, try to get error number
            if ($_.Exception.InnerException.GetType().Name -eq 'SqlException') {
                $sqlEx = $_.Exception.InnerException
                if ($sqlEx.Errors.Count -gt 0) {
                    $errorMessage += "`n      SQL Error Details:"
                    foreach ($sqlError in $sqlEx.Errors) {
                        $errorMessage += "`n        - Error $($sqlError.Number): $($sqlError.Message)"
                        $errorMessage += "`n          Line $($sqlError.LineNumber), Server: $($sqlError.Server)"
                    }
                }
            }
        }
        
        Write-Error "  [ERROR] Failed: $scriptName`n$errorMessage"
        return -1
    }
}

function Sort-DataFilesByDependencies {
    <#
    .SYNOPSIS
        Sorts data files to ensure parent tables are loaded before child tables with FK references.
    #>
    param(
        [System.IO.FileInfo[]]$DataFiles,
        [string]$ServerName,
        [pscredential]$Cred,
        [string]$DatabaseName,
        [hashtable]$Config
    )
    
    if ($DataFiles.Count -le 1) {
        return $DataFiles
    }
    
    Write-Host '  Analyzing foreign key dependencies for data loading order...' -ForegroundColor Gray
    
    try {
        # Connect to server to get FK information
        $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        if ($Cred) {
            $smServer.ConnectionContext.set_LoginSecure($false)
            $smServer.ConnectionContext.set_Login($Cred.UserName)
            $smServer.ConnectionContext.set_SecurePassword($Cred.Password)
        }
        $smServer.ConnectionContext.ConnectTimeout = 15
        $smServer.ConnectionContext.DatabaseName = $DatabaseName
        
        if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
            $smServer.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
        }
        
        $smServer.ConnectionContext.Connect()
        $db = $smServer.Databases[$DatabaseName]
        
        # Build a map of table -> list of tables it depends on (via FKs)
        $dependencies = @{}
        
        foreach ($file in $DataFiles) {
            # Parse filename: Schema.TableName.data.sql
            $fileName = $file.Name
            if ($fileName -match '^(.+?)\.(.+?)\.data\.sql$') {
                $schema = $Matches[1]
                $tableName = $Matches[2]
                $fullTableName = "$schema.$tableName"
                
                $dependencies[$fullTableName] = @()
                
                # Find the table in SMO
                $table = $db.Tables | Where-Object { $_.Schema -eq $schema -and $_.Name -eq $tableName }
                if ($table) {
                    # Get all FK dependencies (tables this table references)
                    foreach ($fk in $table.ForeignKeys) {
                        $referencedSchema = $fk.ReferencedTableSchema
                        $referencedTable = $fk.ReferencedTable
                        $referencedFullName = "$referencedSchema.$referencedTable"
                        
                        # Only track dependency if we're also loading that table
                        if ($DataFiles.Name -contains "$referencedFullName.data.sql") {
                            $dependencies[$fullTableName] += $referencedFullName
                        }
                    }
                }
            }
        }
        
        $smServer.ConnectionContext.Disconnect()
        
        # Topological sort to determine loading order
        $sorted = @()
        $visited = @{}
        $visiting = @{}
        
        function Visit-Table {
            param([string]$tableName)
            
            if ($visited[$tableName]) {
                return
            }
            
            if ($visiting[$tableName]) {
                # Circular dependency detected - this is OK, FK disable should handle it
                Write-Verbose "  Note: Circular FK dependency detected involving $tableName"
                return
            }
            
            $visiting[$tableName] = $true
            
            # Visit dependencies first (parent tables)
            if ($dependencies.ContainsKey($tableName)) {
                foreach ($dep in $dependencies[$tableName]) {
                    Visit-Table $dep
                }
            }
            
            $visiting[$tableName] = $false
            $visited[$tableName] = $true
            $script:sorted += $tableName
        }
        
        # Visit all tables
        foreach ($tableName in $dependencies.Keys) {
            Visit-Table $tableName
        }
        
        # Reorder files based on sorted table names
        $orderedFiles = @()
        foreach ($tableName in $sorted) {
            $file = $DataFiles | Where-Object { $_.Name -eq "$tableName.data.sql" }
            if ($file) {
                $orderedFiles += $file
            }
        }
        
        # Add any files that weren't in the dependency graph (shouldn't happen, but just in case)
        foreach ($file in $DataFiles) {
            if ($file -notin $orderedFiles) {
                $orderedFiles += $file
            }
        }
        
        Write-Host "  [SUCCESS] Ordered $($orderedFiles.Count) data file(s) by FK dependencies" -ForegroundColor Green
        return $orderedFiles
        
    } catch {
        Write-Warning "  [WARNING] Could not analyze FK dependencies: $_"
        Write-Warning '  Using alphabetical order (may cause FK constraint violations)'
        return ($DataFiles | Sort-Object FullName)
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
    if ($IncludeData) {
        $orderedDirs += '20_Data'
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
    Write-Host "Import-SqlServerSchema v2.0" -ForegroundColor Cyan
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
    
    # Validate dependencies
    $execMethod = Test-Dependencies
    Write-Output ''
    
    # Test connection to server
    if (-not (Test-DatabaseConnection -ServerName $Server -Cred $Credential -Config $config)) {
        exit 1
    }
    Write-Output ''
    
    # Check if database exists
    $dbExists = Test-DatabaseExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config
    
    if (-not $dbExists) {
        if ($CreateDatabase) {
            if (-not (New-Database -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config)) {
                exit 1
            }
        } else {
            Write-Error "Database '$Database' does not exist. Use -CreateDatabase to create it."
            exit 1
        }
    } else {
        Write-Output "[SUCCESS] Target database exists: $Database"
    }
    Write-Output ''
    
    # Check for existing schema
    if (Test-SchemaExists -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config) {
        if (-not $Force) {
            Write-Output "[INFO[ Database $Database already contains schema objects."
            Write-Output "Use -Force to proceed with redeployment."
            exit 0
        }
        Write-Output '[INFO[ Proceeding with redeployment due to -Force flag'
    }
    Write-Output ''
    
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
    
    # Detect target server OS for path separator
    $targetOS = Get-TargetServerOS -ServerName $Server -Cred $Credential -Config $config
    $pathSeparator = if ($targetOS -eq 'Linux') { '/' } else { '\' }
    Write-Verbose "Using path separator for $targetOS`: $pathSeparator"
    
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
    $successCount = 0
    $failureCount = 0
    $skipCount = 0
    
    # Track if we need to handle foreign keys for data import
    $dataScripts = $scripts | Where-Object { $_.FullName -match '\\20_Data\\' }
    $nonDataScripts = $scripts | Where-Object { $_.FullName -notmatch '\\20_Data\\' }
    
    # Sort data scripts by FK dependencies to avoid constraint violations
    if ($dataScripts.Count -gt 0) {
        $dataScripts = Sort-DataFilesByDependencies -DataFiles $dataScripts -ServerName $Server `
            -Cred $Credential -DatabaseName $Database -Config $config
    }
    
    # Process non-data scripts first
    foreach ($script in $nonDataScripts) {
        $result = Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
            -DatabaseName $Database -Cred $Credential -Timeout $CommandTimeout -Show:$ShowSQL `
            -SqlCmdVariables $sqlCmdVars -Config $config
        
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
    if ($dataScripts.Count -gt 0 -and $failureCount -eq 0) {
        Write-Output ''
        Write-Output 'Preparing for data import...'
        
        # Disable all foreign key constraints  
        # Get list of FKs and disable them individually
        try {
            $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
            if ($Credential) {
                $smServer.ConnectionContext.set_LoginSecure($false)
                $smServer.ConnectionContext.set_Login($Credential.UserName)
                $smServer.ConnectionContext.set_SecurePassword($Credential.Password)
            }
            $smServer.ConnectionContext.ConnectTimeout = 15
            $smServer.ConnectionContext.DatabaseName = $Database
            
            # Apply TrustServerCertificate from config if specified
            if ($config -and $config.ContainsKey('trustServerCertificate')) {
                $smServer.ConnectionContext.TrustServerCertificate = $config.trustServerCertificate
            }
            
            $smServer.ConnectionContext.Connect()
            
            $db = $smServer.Databases[$Database]
            $fkCount = 0
            
            foreach ($table in $db.Tables) {
                foreach ($fk in $table.ForeignKeys) {
                    if ($fk.IsEnabled) {
                        $alterSql = "ALTER TABLE [$($table.Schema)].[$($table.Name)] NOCHECK CONSTRAINT [$($fk.Name)]"
                        $smServer.ConnectionContext.ExecuteNonQuery($alterSql)
                        $fkCount++
                    }
                }
            }
            
            $smServer.ConnectionContext.Disconnect()
            
            if ($fkCount -gt 0) {
                Write-Output "[SUCCESS] Disabled $fkCount foreign key constraint(s) for data import"
            } else {
                Write-Output '[INFO] No foreign key constraints to disable'
            }
        } catch {
            Write-Warning "[WARNING] Could not disable foreign keys: $_"
            Write-Warning '  Data import may fail if files are not in dependency order'
            Write-Warning '  Attempting to continue with data import...'
        }
        
        Write-Output ''
        Write-Output 'Importing data files...'
        
        # Process data scripts
        foreach ($script in $dataScripts) {
            $result = Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
                -DatabaseName $Database -Cred $Credential -Timeout $CommandTimeout -Show:$ShowSQL `
                -SqlCmdVariables $sqlCmdVars -Config $config
            
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
        try {
            $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
            if ($Credential) {
                $smServer.ConnectionContext.set_LoginSecure($false)
                $smServer.ConnectionContext.set_Login($Credential.UserName)
                $smServer.ConnectionContext.set_SecurePassword($Credential.Password)
            }
            $smServer.ConnectionContext.ConnectTimeout = 15
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
            
            $smServer.ConnectionContext.Disconnect()
            
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
        }
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
    } else {
        Write-Output '[SUCCESS] Import completed successfully'
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
    exit 1
}

#endregion
