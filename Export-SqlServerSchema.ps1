#Requires -Version 7.0

<#
.NOTES
    Version: 1.1.0
    License: MIT
    Repository: https://github.com/ormico/Export-SqlServerSchema

.SYNOPSIS
    Generates SQL scripts to recreate a SQL Server database schema.

.DESCRIPTION
    Exports all database objects (tables, stored procedures, views, etc.) to individual SQL files,
    organized in dependency order for safe re-instantiation. Exports data as INSERT statements.
    Supports Windows and Linux.

.PARAMETER Server
    SQL Server instance (e.g., 'localhost', 'server\SQLEXPRESS', 'server.database.windows.net').
    Required parameter.

.PARAMETER Database
    Database name to script. Required parameter.

.PARAMETER OutputPath
    Directory where scripts will be exported. Defaults to './DbScripts'

.PARAMETER TargetSqlVersion
    Target SQL Server version. Options: 'Sql2012', 'Sql2014', 'Sql2016', 'Sql2017', 'Sql2019', 'Sql2022'.
    Default: 'Sql2022'

.PARAMETER IncludeData
    If specified, data will be exported as INSERT statements. Default is schema only.

.PARAMETER Credential
    PSCredential object for authentication. If not provided, uses integrated Windows authentication.

.PARAMETER ConfigFile
    Path to YAML configuration file for advanced export settings. Optional.

.EXAMPLE
    # Export with Windows auth
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb

    # Export with SQL auth
    $cred = Get-Credential
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb -Credential $cred

    # Export with data
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb -IncludeData -OutputPath ./exports

.NOTES
    Requires: SQL Server Management Objects (SMO)
    Author: Zack Moore
    Updated for PowerShell 7 and modern standards
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = 'SQL Server instance name')]
    [string]$Server,
    
    [Parameter(Mandatory = $true, HelpMessage = 'Database name')]
    [string]$Database,
    
    [Parameter(HelpMessage = 'Output directory for scripts')]
    [string]$OutputPath = './DbScripts',
    
    [Parameter(HelpMessage = 'Target SQL Server version')]
    [ValidateSet('Sql2012', 'Sql2014', 'Sql2016', 'Sql2017', 'Sql2019', 'Sql2022')]
    [string]$TargetSqlVersion = 'Sql2022',
    
    [Parameter(HelpMessage = 'Include data export')]
    [switch]$IncludeData,
    
    [Parameter(HelpMessage = 'SQL Server credentials')]
    [System.Management.Automation.PSCredential]$Credential,
    
    [Parameter(HelpMessage = 'Path to YAML configuration file')]
    [string]$ConfigFile
)

$ErrorActionPreference = 'Stop'

#region Helper Functions

function Test-Dependencies {
    <#
    .SYNOPSIS
        Validates that all required dependencies are available.
    #>
    Write-Output 'Checking dependencies...'
    
    # Check PowerShell version
    if ($PSVersionTable.PSVersion.Major -lt 7) {
        throw "PowerShell 7.0 or later is required. Current version: $($PSVersionTable.PSVersion)"
    }
    
    # Check for SMO assembly
    try {
        # Try to import SqlServer module if available
        if (Get-Module -ListAvailable -Name SqlServer) {
            Import-Module SqlServer -ErrorAction Stop
            Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available (SqlServer module)'
        } else {
            # Fallback to direct assembly load
            Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
            Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available'
        }
    } catch {
        throw "SQL Server Management Objects (SMO) not found. Please install SQL Server Management Studio or the SMO package.`nTo install SMO: Install-Module SqlServer -Scope CurrentUser"
    }
}

function Test-DatabaseConnection {
    <#
    .SYNOPSIS
        Tests connection to the specified SQL Server database.
    #>
    param(
        [string]$ServerName,
        [string]$DatabaseName,
        [pscredential]$Cred
    )
    
    Write-Output "Testing connection to $ServerName\$DatabaseName..."
    
    try {
        if ($Cred) {
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        } else {
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        }
        
        $server.ConnectionContext.ConnectTimeout = 15
        $server.ConnectionContext.Connect()
        
        # Verify database exists
        if ($null -eq $server.Databases[$DatabaseName]) {
            throw "Database '$DatabaseName' not found on server '$ServerName'"
        }
        
        $server.ConnectionContext.Disconnect()
        Write-Output '[SUCCESS] Database connection successful'
        return $true
    } catch {
        Write-Error "[ERROR] Connection failed: $_"
        return $false
    }
}

function Initialize-OutputDirectory {
    <#
    .SYNOPSIS
        Creates and initializes the output directory structure.
    #>
    param([string]$Path)
    
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $exportDir = Join-Path $Path "${Server}_${Database}_${timestamp}"
    
    Write-Host "Creating output directory: $exportDir" -ForegroundColor Gray
    
    $subdirs = @(
        '00_FileGroups',
        '01_DatabaseConfiguration',
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
        '13_Programmability/01_Assemblies',
        '13_Programmability/02_Functions',
        '13_Programmability/03_StoredProcedures',
        '13_Programmability/04_Triggers',
        '13_Programmability/05_Views',
        '14_Synonyms',
        '15_FullTextSearch',
        '16_ExternalData',
        '17_SearchPropertyLists',
        '18_PlanGuides',
        '19_Security',
        '20_Data'
    )
    
    if (-not (Test-Path $exportDir)) {
        New-Item -ItemType Directory -Path $exportDir -Force | Out-Null
    }
    
    foreach ($subdir in $subdirs) {
        $fullPath = Join-Path $exportDir $subdir
        if (-not (Test-Path $fullPath)) {
            New-Item -ItemType Directory -Path $fullPath -Force | Out-Null
        }
    }
    
    return $exportDir
}

function Get-SqlServerVersion {
    <#
    .SYNOPSIS
        Maps version string to SMO SqlServerVersion enum.
    #>
    param([string]$VersionString)
    
    $versionMap = @{
        'Sql2012' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version110
        'Sql2014' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version120
        'Sql2016' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version130
        'Sql2017' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version140
        'Sql2019' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version150
        'Sql2022' = [Microsoft.SqlServer.Management.Smo.SqlServerVersion]::Version160
    }
    
    return $versionMap[$VersionString]
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
    
    Write-Output "[INFO] Loading configuration from: $ConfigFilePath"
    
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
        $config = ConvertFrom-Yaml $yamlContent
        
        # Validate and set defaults for export section
        if (-not $config.export) {
            $config.export = @{}
        }
        if (-not $config.export.excludeObjectTypes) {
            $config.export.excludeObjectTypes = @()
        }
        if (-not $config.export.ContainsKey('includeData')) {
            $config.export.includeData = $false
        }
        if (-not $config.export.excludeObjects) {
            $config.export.excludeObjects = @()
        }
        if (-not $config.export.excludeSchemas) {
            $config.export.excludeSchemas = @()
        }
        
        Write-Output "[SUCCESS] Configuration loaded successfully"
        return $config
        
    } catch {
        Write-Host "[ERROR] Failed to parse configuration file: $_" -ForegroundColor Red
        throw
    }
}

function Show-ExportConfiguration {
    <#
    .SYNOPSIS
        Displays the active export configuration at script start.
    #>
    param(
        [string]$ServerName,
        [string]$DatabaseName,
        [string]$OutputDirectory,
        [hashtable]$Config = @{},
        [bool]$DataExport = $false,
        [string]$ConfigSource = "None (using defaults)"
    )
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Export-SqlServerSchema v2.0" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Server: " -NoNewline -ForegroundColor Gray
    Write-Host $ServerName -ForegroundColor White
    Write-Host "Database: " -NoNewline -ForegroundColor Gray
    Write-Host $DatabaseName -ForegroundColor White
    Write-Host "Output: " -NoNewline -ForegroundColor Gray
    Write-Host $OutputDirectory -ForegroundColor White
    Write-Host ""
    Write-Host "CONFIGURATION" -ForegroundColor Yellow
    Write-Host "-------------" -ForegroundColor Yellow
    Write-Host "Config File: " -NoNewline -ForegroundColor Gray
    Write-Host $ConfigSource -ForegroundColor White
    Write-Host "Include Data: " -NoNewline -ForegroundColor Gray
    Write-Host $(if ($DataExport) { "Yes" } else { "No" }) -ForegroundColor White
    
    # Show excluded object types if any
    if ($Config.export -and $Config.export.excludeObjectTypes -and $Config.export.excludeObjectTypes.Count -gt 0) {
        Write-Host "Excluded Object Types: " -NoNewline -ForegroundColor Gray
        Write-Host ($Config.export.excludeObjectTypes -join ", ") -ForegroundColor Yellow
    } else {
        Write-Host "Excluded Object Types: " -NoNewline -ForegroundColor Gray
        Write-Host "None" -ForegroundColor White
    }
    
    # Show excluded schemas if any
    if ($Config.export -and $Config.export.excludeSchemas -and $Config.export.excludeSchemas.Count -gt 0) {
        Write-Host "Excluded Schemas: " -NoNewline -ForegroundColor Gray
        Write-Host ($Config.export.excludeSchemas -join ", ") -ForegroundColor Yellow
    }
    
    Write-Host ""
    Write-Host "EXPORT STRATEGY" -ForegroundColor Yellow
    Write-Host "---------------" -ForegroundColor Yellow
    Write-Host "[ENABLED] All object types exported by default" -ForegroundColor Green
    
    if ($Config.export -and $Config.export.excludeObjectTypes -and $Config.export.excludeObjectTypes.Count -gt 0) {
        Write-Host "[EXCLUDED] $($Config.export.excludeObjectTypes -join ', ')" -ForegroundColor Yellow
    }
    
    if ($DataExport) {
        Write-Host "[ENABLED] Data export" -ForegroundColor Green
    } else {
        Write-Host "[DISABLED] Data export" -ForegroundColor Gray
    }
    
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "Starting export..." -ForegroundColor Cyan
    Write-Host ""
}

function New-ScriptingOptions {
    <#
    .SYNOPSIS
        Creates a configured ScriptingOptions object.
    #>
    param(
        [Microsoft.SqlServer.Management.Smo.SqlServerVersion]$TargetVersion,
        [hashtable]$Overrides = @{}
    )
    
    $options = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
    
    # Default options for schema export
    $defaults = @{
        AllowSystemObjects           = $false
        AnsiFile                     = $true
        AnsiPadding                  = $true
        AppendToFile                 = $false
        ContinueScriptingOnError     = $true
        TargetServerVersion          = $TargetVersion
        ToFileOnly                   = $true
        IncludeHeaders               = $false
        DriAll                       = $true
        Indexes                      = $true
        Triggers                     = $true
        Permissions                  = $true
        ExtendedProperties           = $true
        ChangeTracking               = $true
        Bindings                     = $true
        ClusteredIndexes             = $true
        NonClusteredIndexes          = $true
        XmlIndexes                   = $true
        FullTextIndexes              = $true
        FullTextCatalogs             = $true
        FullTextStopLists            = $true
        ScriptSchema                 = $true
        ScriptData                   = $false
        NoAssemblies                 = $false
        NoCollation                  = $true
    }
    
    # Merge with overrides
    $finalOptions = $defaults.Clone()
    foreach ($key in $Overrides.Keys) {
        $finalOptions[$key] = $Overrides[$key]
    }
    
    foreach ($key in $finalOptions.Keys) {
        if ($options | Get-Member -Name $key) {
            $options.$key = $finalOptions[$key]
        }
    }
    
    return $options
}

function Export-DatabaseObjects {
    <#
    .SYNOPSIS
        Exports all database objects in dependency order.
    #>
    param(
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        [string]$OutputDir,
        [Microsoft.SqlServer.Management.Smo.Scripter]$Scripter,
        [Microsoft.SqlServer.Management.Smo.SqlServerVersion]$TargetVersion
    )
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORTING DATABASE OBJECTS'
    Write-Output '═══════════════════════════════════════════════'
    
    # 0. FileGroups (Environment-specific, but captured for documentation)
    Write-Output ''
    Write-Output 'Exporting filegroups...'
    $fileGroups = @($Database.FileGroups | Where-Object { $_.Name -ne 'PRIMARY' })
    if ($fileGroups.Count -gt 0) {
        $fgFilePath = Join-Path $OutputDir '00_FileGroups' '001_FileGroups.sql'
        $fgScript = New-Object System.Text.StringBuilder
        [void]$fgScript.AppendLine("-- FileGroups and Files")
        [void]$fgScript.AppendLine("-- WARNING: Physical file paths are environment-specific")
        [void]$fgScript.AppendLine("-- Review and update file paths before applying to target environment")
        [void]$fgScript.AppendLine("")
        
        foreach ($fg in $fileGroups) {
            # Script the filegroup creation
            [void]$fgScript.AppendLine("-- FileGroup: $($fg.Name)")
            [void]$fgScript.AppendLine("-- Type: $($fg.FileGroupType)")
            
            if ($fg.FileGroupType -eq 'RowsFileGroup') {
                [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILEGROUP [$($fg.Name)];")
            } else {
                [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILEGROUP [$($fg.Name)] CONTAINS FILESTREAM;")
            }
            [void]$fgScript.AppendLine("GO")
            
            if ($fg.IsReadOnly) {
                [void]$fgScript.AppendLine("ALTER DATABASE CURRENT MODIFY FILEGROUP [$($fg.Name)] READONLY;")
                [void]$fgScript.AppendLine("GO")
            }
            [void]$fgScript.AppendLine("")
            
            # Script files in the filegroup
            foreach ($file in $fg.Files) {
                # Generate SQLCMD variable name from FileGroup name (e.g., FG_CURRENT -> FG_CURRENT_PATH)
                $sqlcmdVar = "$($fg.Name)_PATH"
                
                # Extract just the filename without path for cross-platform compatibility
                $fileName = Split-Path $file.FileName -Leaf
                if (-not $fileName) { $fileName = "$($file.Name).ndf" }
                
                [void]$fgScript.AppendLine("-- File: $($file.Name)")
                [void]$fgScript.AppendLine("-- Original Path: $($file.FileName)")
                [void]$fgScript.AppendLine("-- Size: $($file.Size)KB, Growth: $($file.Growth)$(if ($file.GrowthType -eq 'KB') {'KB'} else {'%'}), MaxSize: $(if ($file.MaxSize -eq -1) {'UNLIMITED'} else {$file.MaxSize + 'KB'})")
                [void]$fgScript.AppendLine("-- NOTE: Uses SQLCMD variable `$($sqlcmdVar) for base directory path")
                [void]$fgScript.AppendLine("-- Target server will append appropriate path separator and filename")
                [void]$fgScript.AppendLine("-- Configure via fileGroupPathMapping in config file or pass as SQLCMD variable")
                [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILE (")
                [void]$fgScript.AppendLine("    NAME = N'$($file.Name)',")
                # Use $(...)_FILE variable that will be constructed with correct separator on target
                [void]$fgScript.AppendLine("    FILENAME = N'`$($($sqlcmdVar)_FILE)',")
                [void]$fgScript.AppendLine("    SIZE = $($file.Size)KB")
                
                if ($file.Growth -gt 0) {
                    if ($file.GrowthType -eq 'KB') {
                        [void]$fgScript.AppendLine("    , FILEGROWTH = $($file.Growth)KB")
                    } else {
                        [void]$fgScript.AppendLine("    , FILEGROWTH = $($file.Growth)%")
                    }
                }
                
                if ($file.MaxSize -gt 0) {
                    [void]$fgScript.AppendLine("    , MAXSIZE = $($file.MaxSize)KB")
                } elseif ($file.MaxSize -eq -1) {
                    [void]$fgScript.AppendLine("    , MAXSIZE = UNLIMITED")
                }
                
                [void]$fgScript.AppendLine(") TO FILEGROUP [$($fg.Name)];")
                [void]$fgScript.AppendLine("GO")
                [void]$fgScript.AppendLine("")
            }
        }
        
        $fgScript.ToString() | Out-File -FilePath $fgFilePath -Encoding UTF8
        Write-Output "  [SUCCESS] Exported $($fileGroups.Count) filegroup(s)"
        Write-Output "  [WARNING] FileGroups contain environment-specific file paths - manual adjustment required"
    } else {
        Write-Output "  [INFO] No user-defined filegroups found"
    }
    
    # 1. Database Scoped Configurations (Hardware-specific settings)
    Write-Output ''
    Write-Output 'Exporting database scoped configurations...'
    try {
        $dbConfigs = @($Database.DatabaseScopedConfigurations)
        if ($dbConfigs.Count -gt 0) {
            $configFilePath = Join-Path $OutputDir '01_DatabaseConfiguration' '001_DatabaseScopedConfigurations.sql'
            $configScript = New-Object System.Text.StringBuilder
            [void]$configScript.AppendLine("-- Database Scoped Configurations")
            [void]$configScript.AppendLine("-- WARNING: These settings are hardware-specific (e.g., MAXDOP)")
            [void]$configScript.AppendLine("-- Review and adjust for target environment before applying")
            [void]$configScript.AppendLine("")
            
            foreach ($config in $dbConfigs) {
                [void]$configScript.AppendLine("-- Configuration: $($config.Name)")
                [void]$configScript.AppendLine("-- Current Value: $($config.Value)")
                [void]$configScript.AppendLine("ALTER DATABASE SCOPED CONFIGURATION SET $($config.Name) = $($config.Value);")
                [void]$configScript.AppendLine("GO")
                [void]$configScript.AppendLine("")
            }
            
            $configScript.ToString() | Out-File -FilePath $configFilePath -Encoding UTF8
            Write-Output "  [SUCCESS] Exported $($dbConfigs.Count) database scoped configuration(s)"
            Write-Output "  [INFO] Configurations are hardware-specific - review before applying"
        } else {
            Write-Output "  [INFO] No database scoped configurations found"
        }
    } catch {
        Write-Output "  [INFO] Database scoped configurations not available (SQL Server 2016+)"
    }
    
    # Database Scoped Credentials (Structure only - secrets cannot be exported)
    Write-Output ''
    Write-Output 'Exporting database scoped credentials (structure only)...'
    try {
        # Filter to actual credentials (collection may contain null/empty elements)
        $dbCredentials = @($Database.Credentials | Where-Object { $null -ne $_.Name -and $_.Name -ne '' })
        if ($dbCredentials.Count -gt 0) {
            $credFilePath = Join-Path $OutputDir '01_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
            $credScript = New-Object System.Text.StringBuilder
            [void]$credScript.AppendLine("-- Database Scoped Credentials (Structure Only)")
            [void]$credScript.AppendLine("-- WARNING: Secrets cannot be exported and must be provided during import")
            [void]$credScript.AppendLine("-- This file documents the credential names and identities for reference")
            [void]$credScript.AppendLine("")
            
            foreach ($cred in $dbCredentials) {
                [void]$credScript.AppendLine("-- Credential: $($cred.Name)")
                [void]$credScript.AppendLine("-- Identity: $($cred.Identity)")
                [void]$credScript.AppendLine("-- MANUAL ACTION REQUIRED: Create this credential with appropriate secret")
                [void]$credScript.AppendLine("-- Example:")
                [void]$credScript.AppendLine("/*")
                [void]$credScript.AppendLine("CREATE DATABASE SCOPED CREDENTIAL [$($cred.Name)]")
                [void]$credScript.AppendLine("WITH IDENTITY = '$($cred.Identity)',")
                [void]$credScript.AppendLine("SECRET = '<PROVIDE_SECRET_HERE>';")
                [void]$credScript.AppendLine("GO")
                [void]$credScript.AppendLine("*/")
                [void]$credScript.AppendLine("")
            }
            
            $credScript.ToString() | Out-File -FilePath $credFilePath -Encoding UTF8
            Write-Output "  [SUCCESS] Documented $($dbCredentials.Count) database scoped credential(s)"
            Write-Output "  [WARNING] Credentials exported as documentation only - secrets must be provided manually"
        } else {
            Write-Output "  [INFO] No database scoped credentials found"
        }
    } catch {
        Write-Output "  [INFO] Database scoped credentials not available (SQL Server 2016+)"
    }
    
    # 2. Schemas
    Write-Output ''
    Write-Output 'Exporting schemas...'
    $schemas = @($Database.Schemas | Where-Object { -not $_.IsSystemObject -and $_.Name -ne $_.Owner })
    if ($schemas.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '02_Schemas' '001_Schemas.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($schemas)
        Write-Output "  [SUCCESS] Exported $($schemas.Count) schema(s)"
    }
    
    # 3. Sequences
    Write-Output ''
    Write-Output 'Exporting sequences...'
    $sequences = @($Database.Sequences | Where-Object { -not $_.IsSystemObject })
    if ($sequences.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '03_Sequences' '001_Sequences.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($sequences)
        Write-Output "  [SUCCESS] Exported $($sequences.Count) sequence(s)"
    }
    
    # 4. Partition Functions
    Write-Output ''
    Write-Output 'Exporting partition functions...'
    $partitionFunctions = @($Database.PartitionFunctions)
    if ($partitionFunctions.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '04_PartitionFunctions' '001_PartitionFunctions.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($partitionFunctions)
        Write-Output "  [SUCCESS] Exported $($partitionFunctions.Count) partition function(s)"
    }
    
    # 4. Partition Schemes
    Write-Output ''
    Write-Output 'Exporting partition schemes...'
    $partitionSchemes = @($Database.PartitionSchemes)
    if ($partitionSchemes.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '05_PartitionSchemes' '001_PartitionSchemes.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($partitionSchemes)
        Write-Output "  [SUCCESS] Exported $($partitionSchemes.Count) partition scheme(s)"
    }
    
    # 5. User-Defined Types (UDTs, UDTTs, UDDTs)
    Write-Output ''
    Write-Output 'Exporting user-defined types...'
    $allTypes = @()
    $allTypes += @($Database.UserDefinedDataTypes | Where-Object { -not $_.IsSystemObject })
    $allTypes += @($Database.UserDefinedTableTypes | Where-Object { -not $_.IsSystemObject })
    $allTypes += @($Database.UserDefinedTypes | Where-Object { -not $_.IsSystemObject })
    
    if ($allTypes.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '06_Types' '001_UserDefinedTypes.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($allTypes)
        Write-Output "  [SUCCESS] Exported $($allTypes.Count) type(s)"
    }
    
    # 6. XML Schema Collections
    Write-Output ''
    Write-Output 'Exporting XML schema collections...'
    $xmlSchemaCollections = @($Database.XmlSchemaCollections | Where-Object { -not $_.IsSystemObject })
    if ($xmlSchemaCollections.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '07_XmlSchemaCollections' '001_XmlSchemaCollections.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($xmlSchemaCollections)
        Write-Output "  [SUCCESS] Exported $($xmlSchemaCollections.Count) XML schema collection(s)"
    }
    
    # 7. Tables (Primary Keys only - no FK)
    Write-Output ''
    Write-Output 'Exporting tables (PKs only)...'
    $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject })
    if ($tables.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            DriAll              = $false
            DriPrimaryKey       = $true
            DriUniqueKeys       = $true
            DriForeignKeys      = $false
            Indexes             = $false
            ClusteredIndexes    = $false
            NonClusteredIndexes = $false
            XmlIndexes          = $false
            FullTextIndexes     = $false
            Triggers            = $false
        }
        $opts.FileName = Join-Path $OutputDir '08_Tables_PrimaryKey' '001_Tables.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($tables)
        Write-Output "  [SUCCESS] Exported $($tables.Count) table(s)"
    }
    
    # 8. Foreign Keys (separate from table creation)
    Write-Output ''
    Write-Output 'Exporting foreign keys...'
    $foreignKeys = @()
    foreach ($table in $tables) {
        $foreignKeys += @($table.ForeignKeys)
    }
    if ($foreignKeys.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            DriAll            = $false
            DriForeignKeys    = $true
        }
        $opts.FileName = Join-Path $OutputDir '09_Tables_ForeignKeys' '001_ForeignKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($foreignKeys)
        Write-Output "  [SUCCESS] Exported $($foreignKeys.Count) foreign key constraint(s)"
    }
    
    # 9. Indexes
    Write-Output ''
    Write-Output 'Exporting indexes...'
    $indexes = @()
    foreach ($table in $tables) {
        # Filter out indexes that are part of primary keys or unique constraints
        # These are already scripted with the table definition
        $indexes += @($table.Indexes | Where-Object {
            -not $_.IsSystemObject -and
            -not $_.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriPrimaryKey -and
            -not $_.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriUniqueKey
        })
    }
    if ($indexes.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes         = $true
            ClusteredIndexes = $false
            DriPrimaryKey   = $false
            DriUniqueKey    = $false
        }
        $opts.FileName = Join-Path $OutputDir '10_Indexes' '001_Indexes.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($indexes)
        Write-Output "  [SUCCESS] Exported $($indexes.Count) index(es)"
    }
    
    # 10. Defaults
    Write-Output ''
    Write-Output 'Exporting defaults...'
    $defaults = @($Database.Defaults | Where-Object { -not $_.IsSystemObject })
    if ($defaults.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '11_Defaults' '001_Defaults.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($defaults)
        Write-Output "  [SUCCESS] Exported $($defaults.Count) default constraint(s)"
    }
    
    # 11. Rules
    Write-Output ''
    Write-Output 'Exporting rules...'
    $rules = @($Database.Rules | Where-Object { -not $_.IsSystemObject })
    if ($rules.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '12_Rules' '001_Rules.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($rules)
        Write-Output "  [SUCCESS] Exported $($rules.Count) rule(s)"
    }
    
    # 12. Assemblies
    Write-Output ''
    Write-Output 'Exporting assemblies...'
    $assemblies = @($Database.Assemblies | Where-Object { -not $_.IsSystemObject })
    if ($assemblies.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($assembly in $assemblies) {
            $fileName = Join-Path $OutputDir '13_Programmability/01_Assemblies' "$($assembly.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $assembly.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($assemblies.Count) assembly(ies)"
    }
    
    # 13. User-Defined Functions
    Write-Output ''
    Write-Output 'Exporting user-defined functions...'
    $functions = @($Database.UserDefinedFunctions | Where-Object { -not $_.IsSystemObject })
    if ($functions.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes     = $false
            Triggers    = $false
        }
        foreach ($function in $functions) {
            $fileName = Join-Path $OutputDir '13_Programmability/02_Functions' "$($function.Schema).$($function.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $function.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($functions.Count) function(s)"
    }
    
    # 14. User-Defined Aggregates
    Write-Output ''
    Write-Output 'Exporting user-defined aggregates...'
    $aggregates = @($Database.UserDefinedAggregates | Where-Object { -not $_.IsSystemObject })
    if ($aggregates.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($aggregate in $aggregates) {
            $fileName = Join-Path $OutputDir '13_Programmability/02_Functions' "$($aggregate.Schema).$($aggregate.Name).aggregate.sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $aggregate.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($aggregates.Count) aggregate(s)"
    }
    
    # 15. Stored Procedures (including Extended Stored Procedures)
    Write-Output ''
    Write-Output 'Exporting stored procedures...'
    $storedProcs = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject })
    $extendedProcs = @($Database.ExtendedStoredProcedures | Where-Object { -not $_.IsSystemObject })
    if ($storedProcs.Count -gt 0 -or $extendedProcs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes  = $false
            Triggers = $false
        }
        foreach ($proc in $storedProcs) {
            $fileName = Join-Path $OutputDir '13_Programmability/03_StoredProcedures' "$($proc.Schema).$($proc.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $proc.Script($opts)
        }
        foreach ($extProc in $extendedProcs) {
            $fileName = Join-Path $OutputDir '13_Programmability/03_StoredProcedures' "$($extProc.Schema).$($extProc.Name).extended.sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $extProc.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($storedProcs.Count) stored procedure(s) and $($extendedProcs.Count) extended stored procedure(s)"
    }
    
    # 16. Database Triggers
    Write-Output ''
    Write-Output 'Exporting database triggers...'
    $dbTriggers = @($Database.Triggers | Where-Object { -not $_.IsSystemObject })
    if ($dbTriggers.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Triggers = $true
        }
        $opts.FileName = Join-Path $OutputDir '13_Programmability/04_Triggers' '001_DatabaseTriggers.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($dbTriggers)
        Write-Output "  [SUCCESS] Exported $($dbTriggers.Count) database trigger(s)"
    }
    
    # 17. Table Triggers
    Write-Output ''
    Write-Output 'Exporting table triggers...'
    $tableTriggers = @()
    foreach ($table in $tables) {
        $tableTriggers += @($table.Triggers | Where-Object { -not $_.IsSystemObject })
    }
    if ($tableTriggers.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            ClusteredIndexes = $false
            Default          = $false
            DriAll           = $false
            Indexes          = $false
            Triggers         = $true
            ScriptData       = $false
        }
        $opts.FileName = Join-Path $OutputDir '13_Programmability/04_Triggers' '002_TableTriggers.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($tableTriggers)
        Write-Output "  [SUCCESS] Exported $($tableTriggers.Count) table trigger(s)"
    }
    
    # 18. Views
    Write-Output ''
    Write-Output 'Exporting views...'
    $views = @($Database.Views | Where-Object { -not $_.IsSystemObject })
    if ($views.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($view in $views) {
            $fileName = Join-Path $OutputDir '13_Programmability/05_Views' "$($view.Schema).$($view.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $view.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($views.Count) view(s)"
    }
    
    # 19. Synonyms
    Write-Output ''
    Write-Output 'Exporting synonyms...'
    $synonyms = @($Database.Synonyms | Where-Object { -not $_.IsSystemObject })
    if ($synonyms.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($synonym in $synonyms) {
            $fileName = Join-Path $OutputDir '14_Synonyms' "$($synonym.Schema).$($synonym.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $synonym.Script($opts)
        }
        Write-Output "  [SUCCESS] Exported $($synonyms.Count) synonym(s)"
    }
    
    # 20. Full-Text Search
    Write-Output ''
    Write-Output 'Exporting full-text search objects...'
    $ftCatalogs = @($Database.FullTextCatalogs | Where-Object { -not $_.IsSystemObject })
    $ftStopLists = @($Database.FullTextStopLists | Where-Object { -not $_.IsSystemObject })
    
    if ($ftCatalogs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '15_FullTextSearch' '001_FullTextCatalogs.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($ftCatalogs)
        Write-Output "  [SUCCESS] Exported $($ftCatalogs.Count) full-text catalog(s)"
    }
    
    if ($ftStopLists.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '15_FullTextSearch' '002_FullTextStopLists.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($ftStopLists)
        Write-Output "  [SUCCESS] Exported $($ftStopLists.Count) full-text stop list(s)"
    }
    
    # 21. External Data Sources and File Formats
    Write-Output ''
    Write-Output 'Exporting external data sources and file formats...'
    try {
        $externalDataSources = @($Database.ExternalDataSources)
        $externalFileFormats = @($Database.ExternalFileFormats)
        
        if ($externalDataSources.Count -gt 0) {
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $opts.FileName = Join-Path $OutputDir '16_ExternalData' '001_ExternalDataSources.sql'
            $Scripter.Options = $opts
            $Scripter.EnumScript($externalDataSources)
            Write-Output "  [SUCCESS] Exported $($externalDataSources.Count) external data source(s)"
            Write-Output "  [INFO] External data sources contain environment-specific connection strings"
        }
        
        if ($externalFileFormats.Count -gt 0) {
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $opts.FileName = Join-Path $OutputDir '16_ExternalData' '002_ExternalFileFormats.sql'
            $Scripter.Options = $opts
            $Scripter.EnumScript($externalFileFormats)
            Write-Output "  [SUCCESS] Exported $($externalFileFormats.Count) external file format(s)"
        }
        
        if ($externalDataSources.Count -eq 0 -and $externalFileFormats.Count -eq 0) {
            Write-Output "  [INFO] No external data sources or file formats found"
        }
    } catch {
        Write-Output "  [INFO] External data objects not available (SQL Server 2016+ with PolyBase)"
    }
    
    # 22. Search Property Lists
    Write-Output ''
    Write-Output 'Exporting search property lists...'
    try {
        $searchPropertyLists = @($Database.SearchPropertyLists)
        if ($searchPropertyLists.Count -gt 0) {
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $opts.FileName = Join-Path $OutputDir '17_SearchPropertyLists' '001_SearchPropertyLists.sql'
            $Scripter.Options = $opts
            $Scripter.EnumScript($searchPropertyLists)
            Write-Output "  [SUCCESS] Exported $($searchPropertyLists.Count) search property list(s)"
        } else {
            Write-Output "  [INFO] No search property lists found"
        }
    } catch {
        Write-Output "  [INFO] Search property lists not available (SQL Server 2008+)"
    }
    
    # 23. Plan Guides
    Write-Output ''
    Write-Output 'Exporting plan guides...'
    try {
        $planGuides = @($Database.PlanGuides)
        if ($planGuides.Count -gt 0) {
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $opts.FileName = Join-Path $OutputDir '18_PlanGuides' '001_PlanGuides.sql'
            $Scripter.Options = $opts
            $Scripter.EnumScript($planGuides)
            Write-Output "  [SUCCESS] Exported $($planGuides.Count) plan guide(s)"
            Write-Output "  [INFO] Plan guides may need adjustment for target environment query patterns"
        } else {
            Write-Output "  [INFO] No plan guides found"
        }
    } catch {
        Write-Output "  [INFO] Plan guides not available"
    }
    
    # 24. Security Objects (Keys, Certificates, Roles, Users, Audit)
    Write-Output ''
    Write-Output 'Exporting security objects...'
    $asymmetricKeys = @($Database.AsymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $certs = @($Database.Certificates | Where-Object { -not $_.IsSystemObject })
    $symKeys = @($Database.SymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $appRoles = @($Database.ApplicationRoles | Where-Object { -not $_.IsSystemObject })
    $dbRoles = @($Database.Roles | Where-Object { -not $_.IsSystemObject -and -not $_.IsFixedRole })
    $dbUsers = @($Database.Users | Where-Object { -not $_.IsSystemObject })
    $auditSpecs = @($Database.DatabaseAuditSpecifications)
    
    if ($asymmetricKeys.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '001_AsymmetricKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($asymmetricKeys)
        Write-Output "  [SUCCESS] Exported $($asymmetricKeys.Count) asymmetric key(s)"
    }
    
    if ($certs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '002_Certificates.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($certs)
        Write-Output "  [SUCCESS] Exported $($certs.Count) certificate(s)"
    }
    
    if ($symKeys.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '003_SymmetricKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($symKeys)
        Write-Output "  [SUCCESS] Exported $($symKeys.Count) symmetric key(s)"
    }
    
    if ($appRoles.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '004_ApplicationRoles.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($appRoles)
        Write-Output "  [SUCCESS] Exported $($appRoles.Count) application role(s)"
    }
    
    if ($dbRoles.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '005_DatabaseRoles.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($dbRoles)
        Write-Output "  [SUCCESS] Exported $($dbRoles.Count) database role(s)"
    }
    
    if ($dbUsers.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '006_DatabaseUsers.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($dbUsers)
        Write-Output "  [SUCCESS] Exported $($dbUsers.Count) database user(s)"
    }
    
    if ($auditSpecs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '19_Security' '007_DatabaseAuditSpecifications.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($auditSpecs)
        Write-Output "  [SUCCESS] Exported $($auditSpecs.Count) database audit specification(s)"
    }
    
    # Security Policies (Row-Level Security)
    Write-Output ''
    Write-Output 'Exporting security policies (Row-Level Security)...'
    try {
        $securityPolicies = @($Database.SecurityPolicies)
        if ($securityPolicies.Count -gt 0) {
            $policyFilePath = Join-Path $OutputDir '19_Security' '008_SecurityPolicies.sql'
            $policyScript = New-Object System.Text.StringBuilder
            [void]$policyScript.AppendLine("-- Row-Level Security Policies")
            [void]$policyScript.AppendLine("-- NOTE: Ensure predicate functions are created before applying policies")
            [void]$policyScript.AppendLine("")
            
            foreach ($policy in $securityPolicies) {
                # Script the security policy
                $opts = New-ScriptingOptions -TargetVersion $TargetVersion
                $Scripter.Options = $opts
                $policyDef = $Scripter.Script($policy)
                [void]$policyScript.AppendLine("-- Security Policy: $($policy.Schema).$($policy.Name)")
                [void]$policyScript.AppendLine($policyDef -join "`n")
                [void]$policyScript.AppendLine("GO")
                [void]$policyScript.AppendLine("")
            }
            
            $policyScript.ToString() | Out-File -FilePath $policyFilePath -Encoding UTF8
            Write-Output "  [SUCCESS] Exported $($securityPolicies.Count) security policy(ies)"
            Write-Output "  [INFO] Row-Level Security policies require predicate functions to exist first"
        } else {
            Write-Output "  [INFO] No security policies found"
        }
    } catch {
        Write-Output "  [INFO] Security policies not available (SQL Server 2016+)"
    }
}

function Export-TableData {
    <#
    .SYNOPSIS
        Exports table data as INSERT statements.
    #>
    param(
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        [string]$OutputDir,
        [Microsoft.SqlServer.Management.Smo.Scripter]$Scripter,
        [Microsoft.SqlServer.Management.Smo.SqlServerVersion]$TargetVersion
    )
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORTING TABLE DATA'
    Write-Output '═══════════════════════════════════════════════'
    
    $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject })
    
    if ($tables.Count -eq 0) {
        Write-Output 'No tables found.'
        return
    }
    
    $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
        ScriptSchema = $false
        ScriptData   = $true
    }
    
    foreach ($table in $tables) {
        # Use SMO Database object to execute count query
        $countQuery = "SELECT COUNT(*) FROM [$($table.Schema)].[$($table.Name)]"
        $ds = $Database.ExecuteWithResults($countQuery)
        $rowCount = $ds.Tables[0].Rows[0][0]
        
        if ($rowCount -gt 0) {
            $fileName = Join-Path $OutputDir '20_Data' "$($table.Schema).$($table.Name).data.sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $Scripter.EnumScript($table)
            Write-Output "  [SUCCESS] Exported $rowCount row(s) from $($table.Schema).$($table.Name)"
        }
    }
}

function New-DeploymentManifest {
    <#
    .SYNOPSIS
        Creates a README with deployment instructions.
    #>
    param(
        [string]$OutputDir,
        [string]$DatabaseName,
        [string]$ServerName
    )
    
    $exportDate = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    
    # Build manifest content (avoid PowerShell parsing issues with numbered lists)
    $sb = [System.Text.StringBuilder]::new()
    [void]$sb.AppendLine("# Database Schema Export: $DatabaseName")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Export Date: $exportDate")
    [void]$sb.AppendLine("Source Server: $ServerName")
    [void]$sb.AppendLine("Source Database: $DatabaseName")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Deployment Order")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("Scripts must be applied in the following order to ensure all dependencies are satisfied:")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("0. 00_FileGroups - Create filegroups (review paths for target environment)")
    [void]$sb.AppendLine("1. 01_DatabaseConfiguration - Apply database scoped configurations (review hardware-specific settings)")
    [void]$sb.AppendLine("2. 02_Schemas - Create database schemas")
    [void]$sb.AppendLine("3. 03_Sequences - Create sequences")
    [void]$sb.AppendLine("4. 04_PartitionFunctions - Create partition functions")
    [void]$sb.AppendLine("5. 05_PartitionSchemes - Create partition schemes")
    [void]$sb.AppendLine("6. 06_Types - Create user-defined types")
    [void]$sb.AppendLine("7. 07_XmlSchemaCollections - Create XML schema collections")
    [void]$sb.AppendLine("8. 08_Tables_PrimaryKey - Create tables with primary keys (no foreign keys)")
    [void]$sb.AppendLine("9. 09_Tables_ForeignKeys - Add foreign key constraints")
    [void]$sb.AppendLine("10. 10_Indexes - Create indexes")
    [void]$sb.AppendLine("11. 11_Defaults - Create default constraints")
    [void]$sb.AppendLine("12. 12_Rules - Create rules")
    [void]$sb.AppendLine("13. 13_Programmability - Create assemblies, functions, procedures, triggers, views (in subfolder order)")
    [void]$sb.AppendLine("14. 14_Synonyms - Create synonyms")
    [void]$sb.AppendLine("15. 15_FullTextSearch - Create full-text search objects")
    [void]$sb.AppendLine("16. 16_ExternalData - Create external data sources and file formats (review connection strings)")
    [void]$sb.AppendLine("17. 17_SearchPropertyLists - Create search property lists")
    [void]$sb.AppendLine("18. 18_PlanGuides - Create plan guides")
    [void]$sb.AppendLine("19. 19_Security - Create security objects (keys, certificates, roles, users, audit, Row-Level Security)")
    [void]$sb.AppendLine("20. 20_Data - Load data")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Important Notes")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- FileGroups (00): Environment-specific file paths - review and adjust for target server's storage configuration")
    [void]$sb.AppendLine("- Database Configuration (01): Hardware-specific settings like MAXDOP - review for target server capabilities")
    [void]$sb.AppendLine("- External Data (16): Connection strings and URLs are environment-specific - configure for target environment")
    [void]$sb.AppendLine("- Database Scoped Credentials: Always excluded from export (secrets cannot be scripted safely)")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Using Import-SqlServerSchema.ps1")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("To apply this schema to a target database:")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("``````powershell")
    [void]$sb.AppendLine("# Basic usage (Windows authentication) - Dev mode")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`"")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# With SQL authentication")
    [void]$sb.AppendLine("`$cred = Get-Credential")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -Credential `$cred")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Production mode (includes FileGroups, DB Configurations, External Data)")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -ImportMode Prod")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Include data")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -IncludeData")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Create database if it doesn't exist")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -CreateDatabase")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Force apply even if schema already exists")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -Force")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("# Continue on errors (useful for idempotency)")
    [void]$sb.AppendLine("./Import-SqlServerSchema.ps1 -Server `"target-server`" -Database `"target-db`" -SourcePath `"$(Split-Path -Leaf $OutputDir)`" -ContinueOnError")
    [void]$sb.AppendLine("``````")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Notes")
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("- Scripts are in dependency order for initial deployment")
    [void]$sb.AppendLine("- Foreign keys are separated from table creation to ensure all referenced tables exist first")
    [void]$sb.AppendLine("- Triggers and views are deployed after all underlying objects")
    [void]$sb.AppendLine("- Data scripts are optional and can be skipped if desired")
    [void]$sb.AppendLine("- Use -Force flag to redeploy schema even if objects already exist")
    [void]$sb.AppendLine("- Use -ImportMode Dev (default) for development, -ImportMode Prod for production deployments")
    
    $manifestContent = $sb.ToString()
    
    $manifestPath = Join-Path $OutputDir '_DEPLOYMENT_README.md'
    $manifestContent | Out-File -FilePath $manifestPath -Encoding UTF8
    Write-Output "[SUCCESS] Deployment manifest created: $(Split-Path -Leaf $manifestPath)"
}

function Show-ExportSummary {
    <#
    .SYNOPSIS
        Displays summary of exported objects and manual actions required.
    #>
    param(
        [string]$OutputDir,
        [string]$DatabaseName,
        [string]$ServerName,
        [bool]$DataExported
    )
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORT SUMMARY'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output ''
    
    # Count folders and files
    $folders = Get-ChildItem -Path $OutputDir -Directory | Where-Object { $_.Name -match '^\d{2}_' }
    $totalFiles = 0
    $folderSummary = @()
    
    foreach ($folder in $folders | Sort-Object Name) {
        $files = @(Get-ChildItem -Path $folder.FullName -Filter '*.sql' -Recurse)
        if ($files.Count -gt 0) {
            $totalFiles += $files.Count
            $folderName = $folder.Name -replace '^\d{2}_', ''
            $folderSummary += "  [$($files.Count.ToString().PadLeft(3))] $folderName"
        }
    }
    
    Write-Output "Exported from: $ServerName\$DatabaseName"
    Write-Output "Output location: $OutputDir"
    Write-Output ''
    Write-Output "Files created by category:"
    $folderSummary | ForEach-Object { Write-Output $_ }
    Write-Output "  ─────────────────────────"
    Write-Output "  [$($totalFiles.ToString().PadLeft(3))] Total SQL files"
    Write-Output ''
    
    # Check for specific object types requiring manual action
    $manualActions = @()
    
    # Check for Database Scoped Credentials
    $credsPath = Join-Path $OutputDir '01_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
    if (Test-Path $credsPath) {
        $credsContent = Get-Content $credsPath -Raw
        if ($credsContent -match 'CREATE DATABASE SCOPED CREDENTIAL') {
            $manualActions += "[ACTION REQUIRED] Database Scoped Credentials"
            $manualActions += "  Location: 01_DatabaseConfiguration\002_DatabaseScopedCredentials.sql"
            $manualActions += "  Action: Uncomment credential definitions and provide SECRET values"
            $manualActions += "  Note: Secrets cannot be exported - must be manually configured"
        }
    }
    
    # Check for FileGroups
    $fgPath = Join-Path $OutputDir '00_FileGroups'
    if (Test-Path $fgPath) {
        $fgFiles = @(Get-ChildItem -Path $fgPath -Filter '*.sql' -Recurse)
        if ($fgFiles.Count -gt 0) {
            $manualActions += "[ACTION REQUIRED] FileGroups"
            $manualActions += "  Location: 00_FileGroups\"
            $manualActions += "  Action: Review and adjust file paths for target server storage configuration"
            $manualActions += "  Note: Physical file paths are environment-specific"
        }
    }
    
    # Check for Database Configurations
    $dbConfigPath = Join-Path $OutputDir '01_DatabaseConfiguration' '001_DatabaseScopedConfigurations.sql'
    if (Test-Path $dbConfigPath) {
        $manualActions += "[REVIEW RECOMMENDED] Database Scoped Configurations"
        $manualActions += "  Location: 01_DatabaseConfiguration\001_DatabaseScopedConfigurations.sql"
        $manualActions += "  Action: Review MAXDOP and other hardware-specific settings for target server"
    }
    
    # Check for External Data
    $extDataPath = Join-Path $OutputDir '16_ExternalData'
    if (Test-Path $extDataPath) {
        $extFiles = @(Get-ChildItem -Path $extDataPath -Filter '*.sql' -Recurse)
        if ($extFiles.Count -gt 0) {
            $manualActions += "[ACTION REQUIRED] External Data Sources"
            $manualActions += "  Location: 16_ExternalData\"
            $manualActions += "  Action: Review connection strings and URLs for target environment"
            $manualActions += "  Note: External data sources are environment-specific"
        }
    }
    
    # Check for Security Policies (RLS)
    $rlsPath = Join-Path $OutputDir '19_Security' '008_SecurityPolicies.sql'
    if (Test-Path $rlsPath) {
        $rlsContent = Get-Content $rlsPath -Raw
        if ($rlsContent -match 'CREATE SECURITY POLICY') {
            $manualActions += "[INFO] Row-Level Security Policies"
            $manualActions += "  Location: 19_Security\008_SecurityPolicies.sql"
            $manualActions += "  Note: Ensure predicate functions are deployed before applying RLS policies"
        }
    }
    
    if ($manualActions.Count -gt 0) {
        Write-Output "Manual actions and reviews:"
        Write-Output ''
        $manualActions | ForEach-Object { Write-Output $_ }
        Write-Output ''
    }
    
    Write-Output "Next steps:"
    Write-Output "  1. Review _DEPLOYMENT_README.md for deployment instructions"
    Write-Output "  2. Complete any manual actions listed above"
    if ($DataExported) {
        Write-Output "  3. Use Import-SqlServerSchema.ps1 with -ImportMode Dev or -ImportMode Prod"
    } else {
        Write-Output "  3. Use Import-SqlServerSchema.ps1 to deploy to target database"
    }
    Write-Output ''
}

#endregion

#region Main Script

try {
    # Load configuration if provided
    $config = @{ export = @{ excludeObjectTypes = @(); includeData = $false; excludeObjects = @() } }
    $configSource = "None (using defaults)"
    
    if ($ConfigFile) {
        if (Test-Path $ConfigFile) {
            $config = Import-YamlConfig -ConfigFilePath $ConfigFile
            $configSource = $ConfigFile
            
            # Override IncludeData if specified in config
            if ($config.export.includeData -and -not $IncludeData) {
                $IncludeData = $config.export.includeData
                Write-Output "[INFO] Data export enabled from config file"
            }
        } else {
            Write-Warning "Config file not found: $ConfigFile"
            Write-Warning "Continuing with default settings..."
        }
    }
    
    # Validate dependencies
    Test-Dependencies
    
    # Test database connection
    if (-not (Test-DatabaseConnection -ServerName $Server -DatabaseName $Database -Cred $Credential)) {
        exit 1
    }
    
    # Initialize output directory
    $exportDir = Initialize-OutputDirectory -Path $OutputPath
    
    # Display configuration
    Show-ExportConfiguration `
        -ServerName $Server `
        -DatabaseName $Database `
        -OutputDirectory $exportDir `
        -Config $config `
        -DataExport $IncludeData `
        -ConfigSource $configSource
    
    # Connect to SQL Server
    Write-Output 'Connecting to SQL Server...'
    
    if ($Credential) {
        $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
        $smServer.ConnectionContext.LoginSecure = $false
        $smServer.ConnectionContext.Login = $Credential.UserName
        $smServer.ConnectionContext.SecurePassword = $Credential.Password
    } else {
        $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
    }
    
    $smServer.ConnectionContext.ConnectTimeout = 15
    $smServer.ConnectionContext.Connect()
    
    $smDatabase = $smServer.Databases[$Database]
    if ($null -eq $smDatabase) {
        throw "Database '$Database' not found"
    }
    
    Write-Output "[SUCCESS] Connected to $Server\$Database"
    
    # Create scripter
    $sqlVersion = Get-SqlServerVersion -VersionString $TargetSqlVersion
    $scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($smServer)
    $scripter.Options.TargetServerVersion = $sqlVersion
    
    # Export schema objects
    Export-DatabaseObjects -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
    
    # Export data if requested
    if ($IncludeData) {
        Export-TableData -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
    }
    
    # Create deployment manifest
    New-DeploymentManifest -OutputDir $exportDir -DatabaseName $Database -ServerName $Server
    
    # Disconnect
    $smServer.ConnectionContext.Disconnect()
    
    # Show export summary
    Show-ExportSummary -OutputDir $exportDir -DatabaseName $Database -ServerName $Server -DataExported $IncludeData
    
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORT COMPLETE'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output ''
    
} catch {
    Write-Error "[ERROR] Script failed: $_"
    exit 1
}

exit 0

#endregion
# OLD CODE BELOW - KEPT FOR REFERENCE ONLY
# This code is not executed
<#
$scrp.Options.AgentJobId  = $True
$scrp.Options.AgentNotify  = $True
$scrp.Options.AllowSystemObjects  = $False
$scrp.Options.AnsiFile  = $True
$scrp.Options.AnsiPadding  = $True
$scrp.Options.AppendToFile  = $True
#$scrp.Options.BatchSize  = ?some number
$scrp.Options.Bindings  = $True
$scrp.Options.ChangeTracking  = $True
$scrp.Options.ClusteredIndexes  = $True
$scrp.Options.ContinueScriptingOnError  = $True
$scrp.Options.ConvertUserDefinedDataTypesToBaseType  = $False
#$scrp.Options.DdlBodyOnly  = $True
#$scrp.Options.DdlHeaderOnly  = $True
$scrp.Options.Default  = $True
$scrp.Options.DriAll  = $True
#$scrp.Options.DriAllConstraints  = $True
#$scrp.Options.DriAllKeys  = $True
#$scrp.Options.DriChecks  = $True
#$scrp.Options.DriClustered  = $True
#$scrp.Options.DriDefaults  = $True
#$scrp.Options.DriForeignKeys  = $True
#$scrp.Options.DriIncludeSystemNames  = $True
#$scrp.Options.DriIndexes  = $True
#$scrp.Options.DriNonClustered  = $True
#$scrp.Options.DriPrimaryKey  = $True
#$scrp.Options.DriUniqueKeys  = $True
#$scrp.Options.DriWithNoCheck  = $True
#$scrp.Options.Encoding  = $True
#$scrp.Options.EnforceScriptingOptions  = $True
$scrp.Options.ExtendedProperties  = $True
#$scrp.Options.FileName  = $True
$scrp.Options.FullTextCatalogs  = $True
$scrp.Options.FullTextIndexes  = $True
$scrp.Options.FullTextStopLists  = $True
#$scrp.Options.IncludeDatabaseContext  = $True
$scrp.Options.IncludeDatabaseRoleMemberships  = $True
$scrp.Options.IncludeFullTextCatalogRootPath  = $True
#$scrp.Options.IncludeHeaders  = $True
#$scrp.Options.IncludeIfNotExists  = $True
$scrp.Options.Indexes  = $True
#$scrp.Options.LoginSid  = $True
$scrp.Options.NoAssemblies  = $True
$scrp.Options.NoCollation  = $True
#$scrp.Options.NoCommandTerminator  = $True
#$scrp.Options.NoExecuteAs  = $True
#$scrp.Options.NoFileGroup  = $True
#$scrp.Options.NoFileStream  = $True
#$scrp.Options.NoFileStreamColumn  = $True
#$scrp.Options.NoIdentities  = $True
#$scrp.Options.NoIndexPartitioningSchemes  = $True
#$scrp.Options.NoMailProfileAccounts  = $True
#$scrp.Options.NoMailProfilePrincipals  = $True
#$scrp.Options.NonClusteredIndexes  = $True
#$scrp.Options.NoTablePartitioningSchemes  = $True
#$scrp.Options.NoVardecimal  = $True
#$scrp.Options.NoViewColumns  = $True
#$scrp.Options.NoXmlNamespaces  = $True
#$scrp.Options.OptimizerData  = $True
$scrp.Options.Permissions  = $True
#$scrp.Options.PrimaryObject  = $True
#$scrp.Options.SchemaQualify  = $True
#$scrp.Options.SchemaQualifyForeignKeysReferences  = $True
#$scrp.Options.ScriptBatchTerminator  = $True
$scrp.Options.ScriptData  = $False
#$scrp.Options.ScriptDataCompression  = $True
#$scrp.Options.ScriptDrops  = $False
#$scrp.Options.ScriptOwner  = $True
$scrp.Options.ScriptSchema  = $True
#$scrp.Options.Statistics  = $True
$scrp.Options.TargetServerVersion = $TargetServerVersion
#$scrp.Options.TimestampToBinary  = $True
$scrp.Options.ToFileOnly  = $True
$scrp.Options.Triggers  = $False
$scrp.Options.WithDependencies  = $False
$scrp.Options.XmlIndexes  = $True
########END-OPTIONS

$dt = get-date
$scrpFolder = (Get-Location).Path + '\DbScripts\' + $db.Name + '_' + $dt.ToString('yyyyMMdd_HHmmss')  + '\'
echo $scrpFolder
$scrpFile = $scrpFolder +  'schema.table.sql'
$scrpDataFile = $scrpFolder + 'data.sql'
$scrp.Options.FileName = $scrpFile

#if(test-path $scrpFile) { del $scrpFile }
mkdir $scrpFolder

# $scrp.Script($db.Tables)
$toscript = @()

$toscript += $db
if($db.ApplicationRoles -ne $null) { $toscript += $db.ApplicationRoles }
if($db.AsymmetricKeys -ne $null) { $toscript += $db.AsymmetricKeys }
if($db.Certificates -ne $null) { $toscript += $db.Certificates }
if($db.DatabaseAuditSpecifications -ne $null) { $toscript += $db.DatabaseAuditSpecifications }
if($db.Defaults -ne $null) { $toscript += $db.Defaults }
if($db.ExtendedStoredProcedures -ne $null) { $toscript += $db.ExtendedStoredProcedures }
if($db.FullTextCatalogs -ne $null) { $toscript += $db.FullTextCatalogs }
if($db.FullTextStopLists -ne $null) { $toscript += $db.FullTextStopLists }
if($db.PartitionFunctions -ne $null) { $toscript += $db.PartitionFunctions }
if($db.PartitionSchemes -ne $null) { $toscript += $db.PartitionSchemes }
if(($db.Roles | where {$_.IsSystemObject -eq $false}) -ne $null) { $toscript += $db.Roles | where {$_.IsSystemObject -eq $false} }
if(($db.Rules | where {$_.IsSystemObject -eq $false}) -ne $null) { $toscript += $db.Rules | where {$_.IsSystemObject -eq $false} }
if(($db.Schemas | where {$_.Name -ne $_.Owner}) -ne $null) { $toscript += $db.Schemas | where {$_.Name -ne $_.Owner} }
if($db.SymmetricKeys -ne $null) { $toscript += $db.SymmetricKeys }
if($db.Synonyms -ne $null) { $toscript += $db.Synonyms }

#if(($db.Tables | where {$_.IsSystemObject -eq $false}) -ne $null) { $toscript += $db.Tables | where {$_.IsSystemObject -eq $false} }

foreach($table in $db.Tables | where {$_.IsSystemObject -eq $false})
{
    $toscript += $table
    $toscript += $table.Indexes
    $toscript += $table.ForeignKeys

    foreach($col in $table.Columns | where {$_.DefaultConstraint -ne $null})
    {    
        $toscript += $col.DefaultConstraint
    }
}

if($db.UserDefinedDataTypes -ne $null) { $toscript += $db.UserDefinedDataTypes }
if($db.UserDefinedTableTypes -ne $null) { $toscript += $db.UserDefinedTableTypes }
if($db.UserDefinedTypes -ne $null) { $toscript += $db.UserDefinedTypes }
if(($db.Users | where {$_.IsSystemObject -eq $false}) -ne $null) { $toscript += $db.Users | where {$_.IsSystemObject -eq $false} }
if(($db.XmlSchemaCollections | where {$_.IsSystemObject -eq $false}) -ne $null) { $toscript += $db.XmlSchemaCollections | where {$_.IsSystemObject -eq $false} }

$scrp.EnumScript($toscript)

echo "done with Schema"

$options = New-Object "Microsoft.SqlServer.Management.SMO.ScriptingOptions"
$options.IncludeHeaders = $False
$options.AppendToFile = $False
$options.ToFileOnly = $true
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

$toscript = @()
foreach($sproc in $db.Assemblies | where {$_.IsSystemObject -eq $false})
{
    $sprocFQA = $sproc.Name.Replace(".","\\")
    $sprocFileName = $scrpFolder + $sprocFQA + '.assemblies.sproc.sql'
    $options.FileName = $sprocFileName
	
	echo $scrpFile
	$scrpPath = [System.IO.Path]::GetDirectoryName($scrpFile)
	echo $sprocFileName
	$pathExists = test-path $scrpPath
	echo $sprocExists
	if(! $pathExists)
	{
		mkdir $scrpPath
	}
	
    $sproc.Script($options)
    echo $sprocFQA
}
echo 'assemblies'

$options.IncludeHeaders = $False
$options.AppendToFile = $False
$options.ToFileOnly = $true
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

$toscript = @()
foreach($sproc in $db.StoredProcedures | where {$_.IsSystemObject -eq $false})
{
    $sprocFQA = $sproc.Schema + '.' + $sproc.Name
    $sprocFileName = $scrpFolder + $sprocFQA + '.sproc.sql'
    $options.FileName = $sprocFileName
	
	echo $sprocFileName
	$scrpPath = [System.IO.Path]::GetDirectoryName($sprocFileName)
	echo $scrpPath
	$pathExists = test-path $scrpPath
	echo $pathExists
	if(! $pathExists)
	{
		mkdir $scrpPath
	}
	
    $sproc.Script($options)
    echo $sprocFQA
}
echo 'sprocs'

foreach($sproc in $db.UserDefinedAggregates | where {$_.IsSystemObject -eq $false})
{
    $sprocFQA = $sproc.Schema + '.' + $sproc.Name
    $sprocFileName = $scrpFolder + $sprocFQA + '.uda.sql'
    $options.FileName = $sprocFileName
    $sproc.Script($options)
    echo $sprocFQA
}
echo 'aggregates'

foreach($sproc in $db.UserDefinedFunctions | where {$_.IsSystemObject -eq $false})
{
    $sprocFQA = $sproc.Schema + '.' + $sproc.Name
    $sprocFileName = $scrpFolder + $sprocFQA + '.udf.sql'
    $options.FileName = $sprocFileName
    $sproc.Script($options)
    echo $sprocFQA
}
echo 'functions'

#TRIGGERS#

#database triggers
$options = New-Object "Microsoft.SqlServer.Management.SMO.ScriptingOptions"
$options.IncludeHeaders = $False
$options.AppendToFile = $False
$options.ToFileOnly = $True
$options.Triggers  = $True
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

foreach($trigger in $db.Triggers | where {$_.IsSystemObject -eq $false})
{
    $triggerFQA = $db.Name + '.' + $trigger.Name
    $triggerFileName = $scrpFolder + $triggerFQA + '.dbtrigger.sql'
    $options.FileName = $triggerFileName
    $trigger.Script($options)
    echo $triggerFQA
}

#table triggers
$options = New-Object "Microsoft.SqlServer.Management.SMO.ScriptingOptions"
$options.ClusteredIndexes = $False
$options.Default = $False
$options.DriAll = $False
$options.Indexes = $False
$options.IncludeHeaders = $False
$options.AppendToFile = $False
$options.ToFileOnly = $true
$options.Triggers  = $True
$options.ScriptData  = $False
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

foreach($table in $db.Tables | where {$_.IsSystemObject -eq $false})
{
    foreach($trigger in $table.Triggers | where {$_.IsSystemObject -eq $false})
    {
        $triggerFQA = $table.Schema + '.' + $table.Name + '.' + $trigger.Name
        $triggerFileName = $scrpFolder + $triggerFQA + '.trigger.sql'
        $options.FileName = $triggerFileName
        $trigger.Script($options)
        echo $triggerFQA
    }
}

echo "done with triggers"
#END TRIGGERS#

#script views
$options = New-Object "Microsoft.SqlServer.Management.SMO.ScriptingOptions"
$options.ToFileOnly = $True
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

foreach($view in $db.Views | where {$_.IsSystemObject -eq $false})
{
    $viewFQA = $view.Schema + '.' + $view.Name
    $viewFileName = $scrpFolder + $viewFQA + '.view.sql'
    $options.FileName = $viewFileName
    $view.Script($options)
    echo $viewFQA
}
echo 'views'

#end views

#script data
echo 'data'

$options = New-Object "Microsoft.SqlServer.Management.SMO.ScriptingOptions"
$options.FileName = $scrpDataFile
$options.ToFileOnly = $True
$options.ScriptSchema = $False
$options.ScriptData  = $True
$options.TargetServerVersion = $TargetServerVersion

$scrp.Options = $options

foreach($table in $db.Tables | where {$_.IsSystemObject -eq $false})
{
    $tableFQA = $table.Schema + '.' + $table.Name
    echo $tableFQA
    $tableFileName = $scrpFolder + $tableFQA + '.data.sql'
    $options.FileName = $tableFileName
    $scrp.EnumScript($table)
}

echo "done with data"

#>
