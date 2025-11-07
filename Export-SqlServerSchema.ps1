#Requires -Version 7.0

<#
.NOTES
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

.EXAMPLE
    # Export with Windows auth
    ./DB2SCRIPT.ps1 -Server localhost -Database TestDb

    # Export with SQL auth
    $cred = Get-Credential
    ./DB2SCRIPT.ps1 -Server localhost -Database TestDb -Credential $cred

    # Export with data
    ./DB2SCRIPT.ps1 -Server localhost -Database TestDb -IncludeData -OutputPath ./exports

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
    [System.Management.Automation.PSCredential]$Credential
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
            Write-Output '✓ SQL Server Management Objects (SMO) available (SqlServer module)'
        } else {
            # Fallback to direct assembly load
            Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
            Write-Output '✓ SQL Server Management Objects (SMO) available'
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
        Write-Output '✓ Database connection successful'
        return $true
    } catch {
        Write-Error "✗ Connection failed: $_"
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
        '01_Schemas',
        '02_Types',
        '03_Tables_PrimaryKey',
        '04_Tables_ForeignKeys',
        '05_Indexes',
        '06_Defaults',
        '07_Rules',
        '08_Programmability/01_Assemblies',
        '08_Programmability/02_Functions',
        '08_Programmability/03_StoredProcedures',
        '08_Programmability/04_Triggers',
        '08_Programmability/05_Views',
        '09_Synonyms',
        '10_FullTextSearch',
        '11_Security',
        '12_Data'
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
    
    # 1. Schemas
    Write-Output ''
    Write-Output 'Exporting schemas...'
    $schemas = @($Database.Schemas | Where-Object { -not $_.IsSystemObject -and $_.Name -ne $_.Owner })
    if ($schemas.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '01_Schemas' '001_Schemas.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($schemas)
        Write-Output "  ✓ Exported $($schemas.Count) schema(s)"
    }
    
    # 2. User-Defined Types (UDTs, UDTTs, UDDTs)
    Write-Output ''
    Write-Output 'Exporting user-defined types...'
    $allTypes = @()
    $allTypes += @($Database.UserDefinedDataTypes | Where-Object { -not $_.IsSystemObject })
    $allTypes += @($Database.UserDefinedTableTypes | Where-Object { -not $_.IsSystemObject })
    $allTypes += @($Database.UserDefinedTypes | Where-Object { -not $_.IsSystemObject })
    
    if ($allTypes.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '02_Types' '001_UserDefinedTypes.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($allTypes)
        Write-Output "  ✓ Exported $($allTypes.Count) type(s)"
    }
    
    # 3. Tables (Primary Keys only - no FK)
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
        $opts.FileName = Join-Path $OutputDir '03_Tables_PrimaryKey' '001_Tables.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($tables)
        Write-Output "  ✓ Exported $($tables.Count) table(s)"
    }
    
    # 4. Foreign Keys (separate from table creation)
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
        $opts.FileName = Join-Path $OutputDir '04_Tables_ForeignKeys' '001_ForeignKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($foreignKeys)
        Write-Output "  ✓ Exported $($foreignKeys.Count) foreign key constraint(s)"
    }
    
    # 5. Indexes
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
        $opts.FileName = Join-Path $OutputDir '05_Indexes' '001_Indexes.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($indexes)
        Write-Output "  ✓ Exported $($indexes.Count) index(es)"
    }
    
    # 6. Defaults
    Write-Output ''
    Write-Output 'Exporting defaults...'
    $defaults = @($Database.Defaults | Where-Object { -not $_.IsSystemObject })
    if ($defaults.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '06_Defaults' '001_Defaults.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($defaults)
        Write-Output "  ✓ Exported $($defaults.Count) default constraint(s)"
    }
    
    # 7. Rules
    Write-Output ''
    Write-Output 'Exporting rules...'
    $rules = @($Database.Rules | Where-Object { -not $_.IsSystemObject })
    if ($rules.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '07_Rules' '001_Rules.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($rules)
        Write-Output "  ✓ Exported $($rules.Count) rule(s)"
    }
    
    # 8. Assemblies
    Write-Output ''
    Write-Output 'Exporting assemblies...'
    $assemblies = @($Database.Assemblies | Where-Object { -not $_.IsSystemObject })
    if ($assemblies.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($assembly in $assemblies) {
            $fileName = Join-Path $OutputDir '08_Programmability/01_Assemblies' "$($assembly.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $assembly.Script($opts)
        }
        Write-Output "  ✓ Exported $($assemblies.Count) assembly(ies)"
    }
    
    # 9. User-Defined Functions
    Write-Output ''
    Write-Output 'Exporting user-defined functions...'
    $functions = @($Database.UserDefinedFunctions | Where-Object { -not $_.IsSystemObject })
    if ($functions.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes     = $false
            Triggers    = $false
        }
        foreach ($function in $functions) {
            $fileName = Join-Path $OutputDir '08_Programmability/02_Functions' "$($function.Schema).$($function.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $function.Script($opts)
        }
        Write-Output "  ✓ Exported $($functions.Count) function(s)"
    }
    
    # 10. User-Defined Aggregates
    Write-Output ''
    Write-Output 'Exporting user-defined aggregates...'
    $aggregates = @($Database.UserDefinedAggregates | Where-Object { -not $_.IsSystemObject })
    if ($aggregates.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($aggregate in $aggregates) {
            $fileName = Join-Path $OutputDir '08_Programmability/02_Functions' "$($aggregate.Schema).$($aggregate.Name).aggregate.sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $aggregate.Script($opts)
        }
        Write-Output "  ✓ Exported $($aggregates.Count) aggregate(s)"
    }
    
    # 11. Stored Procedures
    Write-Output ''
    Write-Output 'Exporting stored procedures...'
    $storedProcs = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject })
    if ($storedProcs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes  = $false
            Triggers = $false
        }
        foreach ($proc in $storedProcs) {
            $fileName = Join-Path $OutputDir '08_Programmability/03_StoredProcedures' "$($proc.Schema).$($proc.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $proc.Script($opts)
        }
        Write-Output "  ✓ Exported $($storedProcs.Count) stored procedure(s)"
    }
    
    # 12. Database Triggers
    Write-Output ''
    Write-Output 'Exporting database triggers...'
    $dbTriggers = @($Database.Triggers | Where-Object { -not $_.IsSystemObject })
    if ($dbTriggers.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Triggers = $true
        }
        $opts.FileName = Join-Path $OutputDir '08_Programmability/04_Triggers' '001_DatabaseTriggers.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($dbTriggers)
        Write-Output "  ✓ Exported $($dbTriggers.Count) database trigger(s)"
    }
    
    # 13. Table Triggers
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
        $opts.FileName = Join-Path $OutputDir '08_Programmability/04_Triggers' '002_TableTriggers.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($tableTriggers)
        Write-Output "  ✓ Exported $($tableTriggers.Count) table trigger(s)"
    }
    
    # 14. Views
    Write-Output ''
    Write-Output 'Exporting views...'
    $views = @($Database.Views | Where-Object { -not $_.IsSystemObject })
    if ($views.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($view in $views) {
            $fileName = Join-Path $OutputDir '08_Programmability/05_Views' "$($view.Schema).$($view.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $view.Script($opts)
        }
        Write-Output "  ✓ Exported $($views.Count) view(s)"
    }
    
    # 15. Synonyms
    Write-Output ''
    Write-Output 'Exporting synonyms...'
    $synonyms = @($Database.Synonyms | Where-Object { -not $_.IsSystemObject })
    if ($synonyms.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        foreach ($synonym in $synonyms) {
            $fileName = Join-Path $OutputDir '09_Synonyms' "$($synonym.Schema).$($synonym.Name).sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $synonym.Script($opts)
        }
        Write-Output "  ✓ Exported $($synonyms.Count) synonym(s)"
    }
    
    # 16. Full-Text Search
    Write-Output ''
    Write-Output 'Exporting full-text search objects...'
    $ftCatalogs = @($Database.FullTextCatalogs | Where-Object { -not $_.IsSystemObject })
    $ftStopLists = @($Database.FullTextStopLists | Where-Object { -not $_.IsSystemObject })
    
    if ($ftCatalogs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '10_FullTextSearch' '001_FullTextCatalogs.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($ftCatalogs)
        Write-Output "  ✓ Exported $($ftCatalogs.Count) full-text catalog(s)"
    }
    
    if ($ftStopLists.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '10_FullTextSearch' '002_FullTextStopLists.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($ftStopLists)
        Write-Output "  ✓ Exported $($ftStopLists.Count) full-text stop list(s)"
    }
    
    # 17. Security Objects
    Write-Output ''
    Write-Output 'Exporting security objects...'
    $asymmetricKeys = @($Database.AsymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $certs = @($Database.Certificates | Where-Object { -not $_.IsSystemObject })
    $symKeys = @($Database.SymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $appRoles = @($Database.ApplicationRoles | Where-Object { -not $_.IsSystemObject })
    
    if ($asymmetricKeys.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '11_Security' '001_AsymmetricKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($asymmetricKeys)
        Write-Output "  ✓ Exported $($asymmetricKeys.Count) asymmetric key(s)"
    }
    
    if ($certs.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '11_Security' '002_Certificates.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($certs)
        Write-Output "  ✓ Exported $($certs.Count) certificate(s)"
    }
    
    if ($symKeys.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '11_Security' '003_SymmetricKeys.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($symKeys)
        Write-Output "  ✓ Exported $($symKeys.Count) symmetric key(s)"
    }
    
    if ($appRoles.Count -gt 0) {
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $opts.FileName = Join-Path $OutputDir '11_Security' '004_ApplicationRoles.sql'
        $Scripter.Options = $opts
        $Scripter.EnumScript($appRoles)
        Write-Output "  ✓ Exported $($appRoles.Count) application role(s)"
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
            $fileName = Join-Path $OutputDir '12_Data' "$($table.Schema).$($table.Name).data.sql"
            $opts.FileName = $fileName
            $Scripter.Options = $opts
            $Scripter.EnumScript($table)
            Write-Output "  ✓ Exported $rowCount row(s) from $($table.Schema).$($table.Name)"
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
    
    $manifestContent = @"
# Database Schema Export: $DatabaseName

**Export Date**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
**Source Server**: $ServerName
**Source Database**: $DatabaseName

## Deployment Order

Scripts must be applied in the following order to ensure all dependencies are satisfied:

1. **01_Schemas** - Create database schemas
2. **02_Types** - Create user-defined types
3. **03_Tables_PrimaryKey** - Create tables with primary keys (no foreign keys)
4. **04_Tables_ForeignKeys** - Add foreign key constraints
5. **05_Indexes** - Create indexes
6. **06_Defaults** - Create default constraints
7. **07_Rules** - Create rules
8. **08_Programmability** - Create assemblies, functions, procedures, triggers, views (in subfolder order)
9. **09_Synonyms** - Create synonyms
10. **10_FullTextSearch** - Create full-text search objects
11. **11_Security** - Create security objects
12. **12_Data** - Load data

## Using Apply-Schema.ps1

To apply this schema to a target database:

\`\`\`powershell
# Basic usage (Windows authentication)
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)"

# With SQL authentication
\$cred = Get-Credential
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)" -Credential \$cred

# Include data
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)" -IncludeData

# Create database if it doesn't exist
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)" -CreateDatabase

# Force apply even if schema already exists
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)" -Force

# Continue on errors (useful for idempotency)
./Apply-Schema.ps1 -Server "target-server" -Database "target-db" -SourcePath "$(Split-Path -Leaf $OutputDir)" -ContinueOnError
\`\`\`

## Notes

- Scripts are in dependency order for initial deployment
- Foreign keys are separated from table creation to ensure all referenced tables exist first
- Triggers and views are deployed after all underlying objects
- Data scripts are optional and can be skipped if desired
- Use -Force flag to redeploy schema even if objects already exist
"@
    
    $manifestPath = Join-Path $OutputDir '_DEPLOYMENT_README.md'
    $manifestContent | Out-File -FilePath $manifestPath -Encoding UTF8
    Write-Output "✓ Deployment manifest created: $(Split-Path -Leaf $manifestPath)"
}

#endregion

#region Main Script

try {
    # Validate dependencies
    Test-Dependencies
    
    # Test database connection
    if (-not (Test-DatabaseConnection -ServerName $Server -DatabaseName $Database -Cred $Credential)) {
        exit 1
    }
    
    # Initialize output directory
    $exportDir = Initialize-OutputDirectory -Path $OutputPath
    
    # Connect to SQL Server
    Write-Output ''
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
    
    Write-Output "✓ Connected to $Server\$Database"
    
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
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORT COMPLETE'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output "Exported to: $exportDir"
    Write-Output ''
    
} catch {
    Write-Error "✗ Script failed: $_"
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
