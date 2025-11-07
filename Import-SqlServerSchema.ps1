#Requires -Version 7.0

<#
.NOTES
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    Applies SQL Server database schema from exported scripts to a target database.

.DESCRIPTION
    Applies schema scripts in the correct dependency order to recreate database objects on a target server.
    Supports creating the database if it doesn't exist, detecting existing schema, data loading, error handling,
    and idempotent operations.

.PARAMETER Server
    Target SQL Server instance. Required parameter.
    Examples: 'localhost', 'server\SQLEXPRESS', '192.168.1.100', 'server.database.windows.net'

.PARAMETER Database
    Target database name. Will be created if -CreateDatabase is specified and it doesn't exist.
    Required parameter.

.PARAMETER SourcePath
    Path to the directory containing exported schema files (the timestamped folder created by DB2SCRIPT.ps1).
    Required parameter.

.PARAMETER Credential
    PSCredential object for SQL Server authentication. If not provided, uses integrated Windows authentication.

.PARAMETER CreateDatabase
    If specified, creates the target database if it does not exist. Requires appropriate server-level permissions.

.PARAMETER IncludeData
    If specified, includes data loading from the 12_Data folder. Default is schema only.

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
    # Basic usage - apply schema to existing database
    ./Apply-Schema.ps1 -Server localhost -Database TargetDb -SourcePath ".\DbScripts\localhost_SourceDb_20231215_120000"

    # With SQL authentication
    $cred = Get-Credential
    ./Apply-Schema.ps1 -Server localhost -Database TargetDb -SourcePath ".\DbScripts\..." -Credential $cred

    # Create database and apply schema
    ./Apply-Schema.ps1 -Server localhost -Database TargetDb -SourcePath ".\DbScripts\..." -CreateDatabase

    # Include data loading
    ./Apply-Schema.ps1 -Server localhost -Database TargetDb -SourcePath ".\DbScripts\..." -IncludeData

    # Continue on errors (idempotent mode)
    ./Apply-Schema.ps1 -Server localhost -Database TargetDb -SourcePath ".\DbScripts\..." -ContinueOnError

.NOTES
    Requires: sqlcmd (SQL Server Command Line Utility) or .NET SqlConnection
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
    [switch]$ShowSQL
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
    Write-Output '✓ PowerShell 7.0+'
    
    # Check for SMO or sqlcmd
    try {
        # Try to import SqlServer module if available
        if (Get-Module -ListAvailable -Name SqlServer) {
            Import-Module SqlServer -ErrorAction Stop
            Write-Output '✓ SQL Server Management Objects (SMO) available (SqlServer module)'
            return 'SMO'
        } else {
            # Fallback to direct assembly load
            Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
            Write-Output '✓ SQL Server Management Objects (SMO) available'
            return 'SMO'
        }
    } catch {
        Write-Output 'ℹ SMO not found, will attempt to use sqlcmd'
        
        try {
            $sqlcmdPath = Get-Command sqlcmd -ErrorAction Stop
            Write-Output "✓ sqlcmd available at $($sqlcmdPath.Source)"
            return 'SQLCMD'
        } catch {
            throw "Neither SMO nor sqlcmd found. Install SQL Server Management Studio or sqlcmd utility."
        }
    }
}

function Test-DatabaseConnection {
    <#
    .SYNOPSIS
        Tests connection to target SQL Server.
    #>
    param([string]$ServerName, [pscredential]$Cred)
    
    Write-Output "Testing connection to $ServerName..."
    
    try {
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        $server.ConnectionContext.ConnectTimeout = 10
        
        if ($Cred) {
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        }
        
        $server.ConnectionContext.Connect()
        $server.ConnectionContext.Disconnect()
        Write-Output '✓ Connection successful'
        return $true
    } catch {
        Write-Error "✗ Connection failed: $_"
        return $false
    }
}

function Test-DatabaseExists {
    <#
    .SYNOPSIS
        Checks if target database exists.
    #>
    param([string]$ServerName, [string]$DatabaseName, [pscredential]$Cred)
    
    try {
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        if ($Cred) {
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        }
        $server.ConnectionContext.Connect()
        $exists = $null -ne $server.Databases[$DatabaseName]
        $server.ConnectionContext.Disconnect()
        return $exists
    } catch {
        Write-Error "✗ Error checking database: $_"
        return $false
    }
}

function Test-SchemaExists {
    <#
    .SYNOPSIS
        Checks if schema already exists in target database.
    #>
    param([string]$ServerName, [string]$DatabaseName, [pscredential]$Cred)
    
    try {
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        if ($Cred) {
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        }
        $server.ConnectionContext.Connect()
        
        $db = $server.Databases[$DatabaseName]
        if ($null -eq $db) {
            $server.ConnectionContext.Disconnect()
            return $false
        }
        
        # Check if any user tables exist (sign of existing schema)
        $hasObjects = $db.Tables.Count -gt 0 -or $db.Views.Count -gt 0 -or $db.StoredProcedures.Count -gt 0
        $server.ConnectionContext.Disconnect()
        return $hasObjects
    } catch {
        Write-Error "✗ Error checking schema: $_"
        return $false
    }
}

function New-Database {
    <#
    .SYNOPSIS
        Creates a new database on the target server.
    #>
    param([string]$ServerName, [string]$DatabaseName, [pscredential]$Cred)
    
    Write-Output "Creating database $DatabaseName..."
    
    try {
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        if ($Cred) {
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        }
        $server.ConnectionContext.Connect()
        
        $db = [Microsoft.SqlServer.Management.Smo.Database]::new($server, $DatabaseName)
        $db.Create()
        $server.ConnectionContext.Disconnect()
        Write-Output "✓ Database $DatabaseName created"
        return $true
    } catch {
        Write-Error "✗ Failed to create database: $_"
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
        [switch]$Show
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
            Write-Output "  ⊘ Skipped (empty): $scriptName"
            return $true
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
        $server.ConnectionContext.Connect()
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
        
        Write-Output "  ✓ Applied: $scriptName"
        return $true
    } catch {
        $errorMessage = $_.Exception.Message
        if ($_.Exception.InnerException) {
            $errorMessage += " Inner: $($_.Exception.InnerException.Message)"
        }
        Write-Error "  ✗ Failed: $scriptName - $errorMessage"
        return -1
    }
}

function Get-ScriptFiles {
    <#
    .SYNOPSIS
        Gets SQL script files in dependency order.
    #>
    param(
        [string]$Path,
        [switch]$IncludeData
    )
    
    $orderedDirs = @(
        '01_Schemas',
        '02_Types',
        '03_Tables_PrimaryKey',
        '04_Tables_ForeignKeys',
        '05_Indexes',
        '06_Defaults',
        '07_Rules',
        '08_Programmability'
    )
    
    if ($IncludeData) {
        $orderedDirs += '12_Data'
    }
    
    $scripts = @()
    
    foreach ($dir in $orderedDirs) {
        $fullPath = Join-Path $Path $dir
        if (Test-Path $fullPath) {
            $scripts += @(Get-ChildItem -Path $fullPath -Filter '*.sql' -Recurse | 
                Sort-Object FullName)
        }
    }
    
    # Add remaining directories (09_Synonyms, 10_FullTextSearch, 11_Security)
    $remainingDirs = @(
        '09_Synonyms',
        '10_FullTextSearch',
        '11_Security'
    )
    
    foreach ($dir in $remainingDirs) {
        $fullPath = Join-Path $Path $dir
        if (Test-Path $fullPath) {
            $scripts += @(Get-ChildItem -Path $fullPath -Filter '*.sql' -Recurse | 
                Sort-Object FullName)
        }
    }
    
    return $scripts
}

#endregion

#region Main Script

try {
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'DATABASE SCHEMA DEPLOYMENT'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output ''
    
    # Validate dependencies
    $execMethod = Test-Dependencies
    Write-Output ''
    
    # Test connection to server
    if (-not (Test-DatabaseConnection -ServerName $Server -Cred $Credential)) {
        exit 1
    }
    Write-Output ''
    
    # Check if database exists
    $dbExists = Test-DatabaseExists -ServerName $Server -DatabaseName $Database -Cred $Credential
    
    if (-not $dbExists) {
        if ($CreateDatabase) {
            if (-not (New-Database -ServerName $Server -DatabaseName $Database -Cred $Credential)) {
                exit 1
            }
        } else {
            Write-Error "Database '$Database' does not exist. Use -CreateDatabase to create it."
            exit 1
        }
    } else {
        Write-Output "✓ Target database exists: $Database"
    }
    Write-Output ''
    
    # Check for existing schema
    if (Test-SchemaExists -ServerName $Server -DatabaseName $Database -Cred $Credential) {
        if (-not $Force) {
            Write-Output "⚠ Database $Database already contains schema objects."
            Write-Output "Use -Force to proceed with redeployment."
            exit 0
        }
        Write-Output '⚠ Proceeding with redeployment due to -Force flag'
    }
    Write-Output ''
    
    # Get scripts in order
    Write-Output "Collecting scripts from: $(Split-Path -Leaf $SourcePath)"
    $scripts = Get-ScriptFiles -Path $SourcePath -IncludeData:$IncludeData
    
    if ($scripts.Count -eq 0) {
        Write-Error "No SQL scripts found in $SourcePath"
        exit 1
    }
    
    Write-Output "Found $($scripts.Count) script(s)"
    Write-Output ''
    
    # Apply scripts
    Write-Output 'Applying scripts...'
    Write-Output '───────────────────────────────────────────────'
    $successCount = 0
    $failureCount = 0
    $skipCount = 0
    
    # Track if we need to handle foreign keys for data import
    $dataScripts = $scripts | Where-Object { $_.FullName -match '\\12_Data\\' }
    $nonDataScripts = $scripts | Where-Object { $_.FullName -notmatch '\\12_Data\\' }
    
    # Process non-data scripts first
    foreach ($script in $nonDataScripts) {
        $result = Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
            -DatabaseName $Database -Cred $Credential -Timeout $CommandTimeout -Show:$ShowSQL
        
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
                Write-Output "✓ Disabled $fkCount foreign key constraint(s) for data import"
            } else {
                Write-Output 'ℹ No foreign key constraints to disable'
            }
        } catch {
            Write-Output "⚠ Could not disable foreign keys: $_"
            Write-Output '  Continuing with data import anyway...'
        }
        
        Write-Output ''
        Write-Output 'Importing data files...'
        
        # Process data scripts
        foreach ($script in $dataScripts) {
            $result = Invoke-SqlScript -FilePath $script.FullName -ServerName $Server `
                -DatabaseName $Database -Cred $Credential -Timeout $CommandTimeout -Show:$ShowSQL
            
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
                            Write-Error "  ✗ Failed to re-enable FK $($fk.Name) on $($table.Schema).$($table.Name): $_"
                            $errorCount++
                        }
                    }
                }
            }
            
            $smServer.ConnectionContext.Disconnect()
            
            if ($errorCount -gt 0) {
                Write-Error "✗ Foreign key constraint validation failed ($errorCount errors) - data may violate referential integrity"
                $failureCount++
            } elseif ($fkCount -gt 0) {
                Write-Output "✓ Re-enabled and validated $fkCount foreign key constraint(s)"
            } else {
                Write-Output 'ℹ No foreign key constraints to re-enable'
            }
        } catch {
            Write-Error "✗ Error re-enabling foreign keys: $_"
            $failureCount++
        }
    }
    
    Write-Output '───────────────────────────────────────────────'
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'DEPLOYMENT SUMMARY'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output "  ✓ Successful: $successCount"
    Write-Output "  ⊘ Skipped:   $skipCount"
    Write-Output "  ✗ Failed:    $failureCount"
    Write-Output ''
    
    if ($failureCount -eq 0) {
        Write-Output '✓ DEPLOYMENT COMPLETE'
        exit 0
    } else {
        Write-Error "✗ DEPLOYMENT FAILED ($failureCount errors)"
        exit 1
    }
    
} catch {
    Write-Error "✗ Script error: $_"
    exit 1
}

#endregion
