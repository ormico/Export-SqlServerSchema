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
    
    By default, shows milestone-based progress (at 10% intervals). Use -Verbose for detailed 
    per-object progress output.

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
    [string]$ConfigFile,
    
    [Parameter(HelpMessage = 'Connection timeout in seconds (overrides config file)')]
    [int]$ConnectionTimeout = 0,
    
    [Parameter(HelpMessage = 'Command timeout in seconds (overrides config file)')]
    [int]$CommandTimeout = 0,
    
    [Parameter(HelpMessage = 'Maximum retry attempts for transient failures (overrides config file)')]
    [int]$MaxRetries = 0,
    
    [Parameter(HelpMessage = 'Initial retry delay in seconds (overrides config file)')]
    [int]$RetryDelaySeconds = 0,
    
    [Parameter(HelpMessage = 'Collect performance metrics for analysis')]
    [switch]$CollectMetrics
)

$ErrorActionPreference = 'Stop'

# Early module load - required for SMO type resolution in function definitions
try {
    $sqlModule = Get-Module -ListAvailable -Name SqlServer | Sort-Object Version -Descending | Select-Object -First 1
    if ($sqlModule) {
        Import-Module SqlServer -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    }
} catch {
    # Will be handled properly in Test-Dependencies
}

$script:LogFile = $null  # Will be set after output directory is created
$script:VerboseOutput = ($VerbosePreference -eq 'Continue')  # Default is quiet; -Verbose shows per-object progress

# Performance metrics tracking
$script:Metrics = @{
    StartTime = $null
    EndTime = $null
    TotalDurationMs = 0
    ConnectionTimeMs = 0
    Categories = [ordered]@{}
    ObjectCounts = [ordered]@{}
    TotalObjectsExported = 0
    TotalFilesCreated = 0
    Errors = 0
}

#region Helper Functions

function Start-MetricsTimer {
    <#
    .SYNOPSIS
        Starts a stopwatch for timing a category of operations.
    #>
    param([string]$Category)
    
    if (-not $script:CollectMetrics) { return $null }
    
    $timer = [System.Diagnostics.Stopwatch]::StartNew()
    return $timer
}

function Stop-MetricsTimer {
    <#
    .SYNOPSIS
        Stops a timer and records the elapsed time for a category.
    #>
    param(
        [string]$Category,
        [System.Diagnostics.Stopwatch]$Timer,
        [int]$ObjectCount = 0,
        [int]$SuccessCount = 0,
        [int]$FailCount = 0
    )
    
    if (-not $script:CollectMetrics -or $null -eq $Timer) { return }
    
    $Timer.Stop()
    
    $script:Metrics.Categories[$Category] = @{
        DurationMs = $Timer.ElapsedMilliseconds
        ObjectCount = $ObjectCount
        SuccessCount = $SuccessCount
        FailCount = $FailCount
        AvgMsPerObject = if ($ObjectCount -gt 0) { [math]::Round($Timer.ElapsedMilliseconds / $ObjectCount, 2) } else { 0 }
    }
    
    $script:Metrics.TotalObjectsExported += $SuccessCount
    $script:Metrics.Errors += $FailCount
}

function Write-ObjectProgress {
    <#
    .SYNOPSIS
        Writes progress for an object export. Default shows milestone progress; -Verbose shows every object.
    .DESCRIPTION
        Phase 4 optimization: Reduces console I/O overhead by batching progress output.
        Default mode writes at 10% intervals. With -Verbose, writes every object.
    #>
    param(
        [string]$ObjectName,
        [int]$Current,
        [int]$Total,
        [switch]$Success,
        [switch]$Failed
    )
    
    $percentComplete = [math]::Round(($Current / $Total) * 100)
    
    if ($script:VerboseOutput) {
        # Verbose mode - show every object with SUCCESS/FAILED status
        # Only print object name on initial call (no Success/Failed flag)
        if (-not $Success -and -not $Failed) {
            Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $ObjectName)
        } elseif ($Success) {
            Write-Host "        [SUCCESS]" -ForegroundColor Green
        } elseif ($Failed) {
            Write-Host "        [FAILED]" -ForegroundColor Red
        }
    } else {
        # Default mode - only show progress at 10% intervals or for failures
        # Skip the -Success calls entirely - we already showed progress at milestone
        if ($Success) { return }
        
        $milestone = [math]::Floor($percentComplete / 10) * 10
        $prevMilestone = if ($Current -gt 1) { [math]::Floor((($Current - 1) / $Total) * 100 / 10) * 10 } else { -1 }
        
        if ($Failed) {
            # Always show failures
            Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $ObjectName)
            Write-Host "        [FAILED]" -ForegroundColor Red
        } elseif ($milestone -gt $prevMilestone -or $Current -eq $Total) {
            # Show at milestones (10%, 20%, etc.) and at completion
            Write-Host ("  [{0,3}%] {1} of {2} completed..." -f $percentComplete, $Current, $Total)
        }
    }
}

function Save-PerformanceMetrics {
    <#
    .SYNOPSIS
        Saves collected metrics to a JSON file and displays summary.
    #>
    param(
        [string]$OutputDir
    )
    
    if (-not $script:CollectMetrics) { return }
    
    $script:Metrics.EndTime = Get-Date
    $script:Metrics.TotalDurationMs = ($script:Metrics.EndTime - $script:Metrics.StartTime).TotalMilliseconds
    
    # Count total files created
    $script:Metrics.TotalFilesCreated = (Get-ChildItem -Path $OutputDir -Filter '*.sql' -Recurse).Count
    
    # Display metrics summary
    Write-Output ''
    Write-Output '==============================================='
    Write-Output 'PERFORMANCE METRICS'
    Write-Output '==============================================='
    Write-Output ''
    Write-Output ("Total Duration: {0:N2} seconds" -f ($script:Metrics.TotalDurationMs / 1000))
    Write-Output ("Connection Time: {0:N2} seconds" -f ($script:Metrics.ConnectionTimeMs / 1000))
    Write-Output ("Export Time: {0:N2} seconds" -f (($script:Metrics.TotalDurationMs - $script:Metrics.ConnectionTimeMs) / 1000))
    Write-Output ''
    Write-Output 'Time by Category:'
    Write-Output '-----------------'
    
    $sortedCategories = $script:Metrics.Categories.GetEnumerator() | Sort-Object { $_.Value.DurationMs } -Descending
    foreach ($cat in $sortedCategories) {
        $pct = if ($script:Metrics.TotalDurationMs -gt 0) { 
            [math]::Round(($cat.Value.DurationMs / $script:Metrics.TotalDurationMs) * 100, 1) 
        } else { 0 }
        
        Write-Output ("  {0,-35} {1,8:N0}ms ({2,5:N1}%) - {3} objects @ {4:N1}ms/obj" -f `
            $cat.Key, 
            $cat.Value.DurationMs, 
            $pct,
            $cat.Value.ObjectCount,
            $cat.Value.AvgMsPerObject)
    }
    
    Write-Output ''
    Write-Output 'Summary:'
    Write-Output '---------'
    Write-Output "  Total Objects Exported: $($script:Metrics.TotalObjectsExported)"
    Write-Output "  Total Files Created: $($script:Metrics.TotalFilesCreated)"
    Write-Output "  Errors: $($script:Metrics.Errors)"
    Write-Output ''
    
    # Save to JSON file
    $metricsFile = Join-Path $OutputDir 'performance-metrics.json'
    $metricsJson = @{
        ExportDate = $script:Metrics.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
        TotalDurationSeconds = [math]::Round($script:Metrics.TotalDurationMs / 1000, 2)
        ConnectionTimeSeconds = [math]::Round($script:Metrics.ConnectionTimeMs / 1000, 2)
        ExportTimeSeconds = [math]::Round(($script:Metrics.TotalDurationMs - $script:Metrics.ConnectionTimeMs) / 1000, 2)
        TotalObjectsExported = $script:Metrics.TotalObjectsExported
        TotalFilesCreated = $script:Metrics.TotalFilesCreated
        Errors = $script:Metrics.Errors
        Categories = @{}
    }
    
    foreach ($cat in $script:Metrics.Categories.GetEnumerator()) {
        $metricsJson.Categories[$cat.Key] = @{
            DurationSeconds = [math]::Round($cat.Value.DurationMs / 1000, 3)
            ObjectCount = $cat.Value.ObjectCount
            SuccessCount = $cat.Value.SuccessCount
            FailCount = $cat.Value.FailCount
            AvgMsPerObject = $cat.Value.AvgMsPerObject
        }
    }
    
    $metricsJson | ConvertTo-Json -Depth 5 | Out-File -FilePath $metricsFile -Encoding UTF8
    Write-Output "[SUCCESS] Metrics saved to: $(Split-Path -Leaf $metricsFile)"
    Write-Output ''
}

function Write-Log {
    <#
    .SYNOPSIS
        Writes message to console and log file with timestamp.
    #>
    param(
        [string]$Message,
        [ValidateSet('INFO', 'SUCCESS', 'WARNING', 'ERROR')]
        [string]$Level = 'INFO'
    )
    
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry = "[$timestamp] [$Level] $Message"
    
    # Write to console (existing behavior)
    switch ($Level) {
        'SUCCESS' { Write-Host $Message -ForegroundColor Green }
        'WARNING' { Write-Warning $Message }
        'ERROR'   { Write-Host $Message -ForegroundColor Red }
        default   { Write-Output $Message }
    }
    
    # Also write to log file if available
    if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
        try {
            Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            # Silently fail if log write fails - don't interrupt main operation
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

function Write-ExportError {
    <#
    .SYNOPSIS
        Logs detailed error information including all nested exceptions and context.
    #>
    param(
        [string]$ObjectType,
        [string]$ObjectName,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string]$AdditionalContext = '',
        [string]$FilePath = ''
    )
    
    $errorMsg = "Failed to export $ObjectType$(if ($ObjectName) { ": $ObjectName" })"
    Write-Host "[ERROR] $errorMsg" -ForegroundColor Red
    
    if ($FilePath) {
        Write-Host "  Target File: $FilePath" -ForegroundColor Yellow
        Write-Host "  Path Length: $($FilePath.Length) characters" -ForegroundColor Yellow
    }
    
    if ($AdditionalContext) {
        Write-Host "  Context: $AdditionalContext" -ForegroundColor Yellow
    }
    
    # Build detailed log entry
    $logDetails = @"
[ERROR] $errorMsg
$(if ($FilePath) { "Target File: $FilePath (length: $($FilePath.Length))" })
$(if ($AdditionalContext) { "Context: $AdditionalContext" })
"@
    
    # Walk the exception chain
    $currentException = $ErrorRecord.Exception
    $depth = 0
    
    while ($null -ne $currentException) {
        $indent = '  ' + ('  ' * $depth)
        
        if ($depth -eq 0) {
            $exMsg = "${indent}Exception: $($currentException.GetType().FullName)"
            Write-Host $exMsg -ForegroundColor Red
            $logDetails += "`n$exMsg"
        } else {
            $exMsg = "${indent}Inner Exception: $($currentException.GetType().FullName)"
            Write-Host $exMsg -ForegroundColor Yellow
            $logDetails += "`n$exMsg"
        }
        
        $msgLine = "${indent}Message: $($currentException.Message)"
        Write-Host $msgLine -ForegroundColor Gray
        $logDetails += "`n$msgLine"
        
        # Show SQL-specific information if available
        if ($currentException -is [Microsoft.SqlServer.Management.Common.ExecutionFailureException]) {
            $sqlMsg = "${indent}SQL Server Error"
            Write-Host $sqlMsg -ForegroundColor Yellow
            $logDetails += "`n$sqlMsg"
        }
        if ($currentException.InnerException -is [Microsoft.SqlServer.Management.Smo.FailedOperationException]) {
            $smoMsg = "${indent}SMO Operation Failed"
            Write-Host $smoMsg -ForegroundColor Yellow
            $logDetails += "`n$smoMsg"
        }
        
        $currentException = $currentException.InnerException
        $depth++
        
        # Prevent infinite loops
        if ($depth -gt 10) {
            $truncMsg = "${indent}... (exception chain truncated)"
            Write-Host $truncMsg -ForegroundColor Gray
            $logDetails += "`n$truncMsg"
            break
        }
    }
    
    # Show script stack trace for first level only
    if ($ErrorRecord.ScriptStackTrace) {
        $stackMsg = "  Stack: $($ErrorRecord.ScriptStackTrace.Split("`n")[0])"
        Write-Host $stackMsg -ForegroundColor DarkGray
        $logDetails += "`n$stackMsg"
    }
    
    # Write to log file
    if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
        try {
            Add-Content -Path $script:LogFile -Value "`n$logDetails`n" -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {
            # Silently fail if log write fails
        }
    }
}

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
        $sqlModule = Get-Module -ListAvailable -Name SqlServer | Sort-Object Version -Descending | Select-Object -First 1
        if ($sqlModule) {
            Import-Module SqlServer -ErrorAction Stop -WarningAction SilentlyContinue
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
        [pscredential]$Cred,
        [hashtable]$Config,
        [int]$Timeout = 30
    )
    
    Write-Output "Testing connection to $ServerName\$DatabaseName..."
    
    $server = $null
    try {
        if ($Cred) {
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $Cred.UserName
            $server.ConnectionContext.SecurePassword = $Cred.Password
        } else {
            $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ServerName)
        }
        
        $server.ConnectionContext.ConnectTimeout = $Timeout
        
        # Apply TrustServerCertificate from config if specified
        if ($Config -and $Config.ContainsKey('trustServerCertificate')) {
            $server.ConnectionContext.TrustServerCertificate = $Config.trustServerCertificate
        }
        
        $server.ConnectionContext.Connect()
        
        # Verify database exists
        if ($null -eq $server.Databases[$DatabaseName]) {
            throw "Database '$DatabaseName' not found on server '$ServerName'"
        }
        
        Write-Output '[SUCCESS] Database connection successful'
        return $true
    } catch {
        Write-Error "[ERROR] Connection failed: $_"
        return $false
    } finally {
        if ($server -and $server.ConnectionContext.IsOpen) {
            $server.ConnectionContext.Disconnect()
        }
    }
}

function Get-SafeFileName {
    <#
    .SYNOPSIS
        Sanitizes a string to be used as a filename.
    .DESCRIPTION
        Replaces invalid filesystem characters with underscores.
        Handles characters that are invalid on Windows, Linux, and macOS.
        Also handles path length limitations.
    #>
    param([string]$Name)
    
    # Replace invalid filesystem characters with underscore
    # Windows: < > : " / \ | ? *
    # Also handle control characters (0x00-0x1F)
    $invalidChars = '[<>:"/\\|?*\x00-\x1F]'
    $safeName = $Name -replace $invalidChars, '_'
    
    # Remove leading/trailing dots and spaces (problematic on Windows)
    $safeName = $safeName.Trim('. ')
    
    # Windows reserves these filenames (CON, PRN, AUX, NUL, COM1-9, LPT1-9)
    $reservedNames = '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)'
    if ($safeName -match $reservedNames) {
        $safeName = "_$safeName"
    }
    
    # Ensure the name is not empty after sanitization
    if ([string]::IsNullOrWhiteSpace($safeName)) {
        $safeName = 'unnamed'
    }
    
    # Truncate if too long (keep 200 chars max to allow for path + extensions)
    if ($safeName.Length -gt 200) {
        $safeName = $safeName.Substring(0, 200)
    }
    
    return $safeName
}

function Ensure-DirectoryExists {
    <#
    .SYNOPSIS
        Ensures a directory exists, creating it if necessary.
    .DESCRIPTION
        Helper function to ensure SMO can write to the target directory.
        Creates parent directories if they don't exist.
    #>
    param([string]$FilePath)
    
    $directory = Split-Path $FilePath -Parent
    if ($directory -and -not (Test-Path $directory)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }
}

function Initialize-OutputDirectory {
    <#
    .SYNOPSIS
        Creates and initializes the output directory structure.
    #>
    param([string]$Path)
    
    # Convert to absolute path if relative
    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        $Path = Join-Path (Get-Location).Path $Path
    }
    
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
    
    Write-Verbose "Get-SqlServerVersion called with: '$VersionString'"
    
    try {
        # Map version strings to enum value names
        $versionNameMap = @{
            'Sql2012' = 'Version110'
            'Sql2014' = 'Version120'
            'Sql2016' = 'Version130'
            'Sql2017' = 'Version140'
            'Sql2019' = 'Version150'
            'Sql2022' = 'Version160'
        }
        
        if (-not $versionNameMap.ContainsKey($VersionString)) {
            Write-Error "Invalid SQL Server version: '$VersionString'. Valid values: $($versionNameMap.Keys -join ', ')"
            throw "Invalid SQL Server version: $VersionString"
        }
        
        # Convert enum name to actual enum value using dynamic type resolution
        $enumTypeName = 'Microsoft.SqlServer.Management.Smo.SqlServerVersion'
        $enumType = $enumTypeName -as [Type]
        if ($null -eq $enumType) {
            throw "Cannot resolve type [$enumTypeName]. Ensure SqlServer module is loaded."
        }
        
        $enumValueName = $versionNameMap[$VersionString]
        $result = [Enum]::Parse($enumType, $enumValueName)
        
        Write-Verbose "Get-SqlServerVersion returning: $result ($($result.GetType().FullName))"
        return $result
    }
    catch {
        Write-Error "Error in Get-SqlServerVersion for '$VersionString': $_"
        throw
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
        
        Write-Host "[SUCCESS] Configuration loaded successfully" -ForegroundColor Green
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
    Write-Host "Export-SqlServerSchema" -ForegroundColor Cyan
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
        $TargetVersion,  # Don't type this as SMO enum - allow dynamic resolution
        [hashtable]$Overrides = @{}
    )
    
    $targetType = if ($TargetVersion) { $TargetVersion.GetType().FullName } else { 'NULL' }
    
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

function Test-ObjectTypeExcluded {
    <#
    .SYNOPSIS
        Checks if an object type should be excluded from export based on configuration.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [string]$ObjectType
    )
    
    # Use script-level $Config variable
    if ($script:Config -and $script:Config.export -and $script:Config.export.excludeObjectTypes) {
        return $script:Config.export.excludeObjectTypes -contains $ObjectType
    }
    
    return $false
}

function Test-SchemaExcluded {
    <#
    .SYNOPSIS
        Checks if a schema should be excluded from export based on configuration.
    #>
    param(
        [string]$Schema
    )

    if ([string]::IsNullOrWhiteSpace($Schema)) {
        return $false
    }

    if ($script:Config -and $script:Config.export -and $script:Config.export.excludeSchemas) {
        return $script:Config.export.excludeSchemas -contains $Schema
    }

    return $false
}

function Test-ObjectExcluded {
    <#
    .SYNOPSIS
        Checks if a schema-bound object should be excluded based on configuration.
    #>
    param(
        [string]$Schema,
        [string]$Name
    )

    if (Test-SchemaExcluded -Schema $Schema) {
        return $true
    }

    if (-not $Name) {
        return $false
    }

    if ($script:Config -and $script:Config.export -and $script:Config.export.excludeObjects) {
        $fullName = if ([string]::IsNullOrWhiteSpace($Schema)) { $Name } else { "$Schema.$Name" }
        foreach ($pattern in $script:Config.export.excludeObjects) {
            if ($fullName -ilike $pattern) {
                return $true
            }
        }
    }

    return $false
}

function Export-DatabaseObjects {
    <#
    .SYNOPSIS
        Exports all database objects in dependency order.
    .OUTPUTS
        Returns a hashtable with TotalObjects, SuccessCount, and FailCount for metrics.
    #>
    param(
        $Database,  # Don't type-constrain SMO objects
        [string]$OutputDir,
        $Scripter,  # Don't type-constrain SMO objects
        $TargetVersion  # Don't type-constrain SMO enums
    )
    
    # Initialize metrics tracking for this function
    $functionMetrics = @{
        TotalObjects = 0
        SuccessCount = 0
        FailCount = 0
        CategoryTimings = [ordered]@{}
    }
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORTING DATABASE OBJECTS'
    Write-Output '═══════════════════════════════════════════════'
    
    # 0. FileGroups (Environment-specific, but captured for documentation)
    Write-Output ''
    Write-Output 'Exporting filegroups...'
    if (Test-ObjectTypeExcluded -ObjectType 'FileGroups') {
        Write-Host '  [SKIPPED] FileGroups excluded by configuration' -ForegroundColor Yellow
    } else {
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
    }
    
    # 1. Database Scoped Configurations (Hardware-specific settings)
    Write-Output ''
    Write-Output 'Exporting database scoped configurations...'
    if (Test-ObjectTypeExcluded -ObjectType 'DatabaseScopedConfigurations') {
        Write-Host '  [SKIPPED] DatabaseScopedConfigurations excluded by configuration' -ForegroundColor Yellow
    } else {
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
    }
    
    # Database Scoped Credentials (Structure only - secrets cannot be exported)
    Write-Output ''
    Write-Output 'Exporting database scoped credentials (structure only)...'
    if (Test-ObjectTypeExcluded -ObjectType 'DatabaseScopedCredentials') {
        Write-Host '  [SKIPPED] DatabaseScopedCredentials excluded by configuration' -ForegroundColor Yellow
    } else {
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
    }
    
    # 2. Schemas
    Write-Output ''
    Write-Output 'Exporting schemas...'
    if (Test-ObjectTypeExcluded -ObjectType 'Schemas') {
        Write-Host '  [SKIPPED] Schemas excluded by configuration' -ForegroundColor Yellow
    } else {
    $schemas = @($Database.Schemas | Where-Object { -not $_.IsSystemObject -and $_.Name -ne $_.Owner -and -not (Test-SchemaExcluded -Schema $_.Name) })
    if ($schemas.Count -gt 0) {
        Write-Output "  Found $($schemas.Count) schema(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($schema in $schemas) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $schemas.Count) * 100)
            try {
                Write-ObjectProgress -ObjectName $schema.Name -Current $currentItem -Total $schemas.Count
                $safeName = Get-SafeFileName $schema.Name
                $fileName = Join-Path $OutputDir '02_Schemas' "$safeName.sql"
                
                # Ensure directory exists and validate path
                Ensure-DirectoryExists $fileName
                if (-not (Test-Path (Split-Path $fileName -Parent))) {
                    throw "Failed to create directory: $(Split-Path $fileName -Parent)"
                }
                
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $schema.Script($opts) | Out-Null
                Write-ObjectProgress -ObjectName $schema.Name -Current $currentItem -Total $schemas.Count -Success
                $successCount++
            } catch {
                Write-ObjectProgress -ObjectName $schema.Name -Current $currentItem -Total $schemas.Count -Failed
                Write-ExportError -ObjectType 'Schema' -ObjectName $schema.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
            Write-Output "  [SUMMARY] Exported $successCount/$($schemas.Count) schema(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 3. Sequences
    Write-Output ''
    Write-Output 'Exporting sequences...'
    if (Test-ObjectTypeExcluded -ObjectType 'Sequences') {
        Write-Host '  [SKIPPED] Sequences excluded by configuration' -ForegroundColor Yellow
    } else {
    $sequences = @($Database.Sequences | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($sequences.Count -gt 0) {
        Write-Output "  Found $($sequences.Count) sequence(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($sequence in $sequences) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $sequences.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $sequence.Schema, $sequence.Name)
                $safeSchema = Get-SafeFileName $sequence.Schema
                $safeName = Get-SafeFileName $sequence.Name
                $fileName = Join-Path $OutputDir '03_Sequences' "$safeSchema.$safeName.sql"
                
                # Ensure directory exists and validate path
                Ensure-DirectoryExists $fileName
                if (-not (Test-Path (Split-Path $fileName -Parent))) {
                    throw "Failed to create directory: $(Split-Path $fileName -Parent)"
                }
                
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $sequence.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Sequence' -ObjectName "$($sequence.Schema).$($sequence.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($sequences.Count) sequence(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 4. Partition Functions
    Write-Output ''
    Write-Output 'Exporting partition functions...'
    if (Test-ObjectTypeExcluded -ObjectType 'PartitionFunctions') {
        Write-Host '  [SKIPPED] PartitionFunctions excluded by configuration' -ForegroundColor Yellow
    } else {
    $partitionFunctions = @($Database.PartitionFunctions | Where-Object { -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($partitionFunctions.Count -gt 0) {
        Write-Output "  Found $($partitionFunctions.Count) partition function(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($pf in $partitionFunctions) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $partitionFunctions.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $pf.Name)
                $fileName = Join-Path $OutputDir '04_PartitionFunctions' "$(Get-SafeFileName $($pf.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $pf.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'PartitionFunction' -ObjectName $pf.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($partitionFunctions.Count) partition function(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 5. Partition Schemes
    Write-Output ''
    Write-Output 'Exporting partition schemes...'
    if (Test-ObjectTypeExcluded -ObjectType 'PartitionSchemes') {
        Write-Host '  [SKIPPED] PartitionSchemes excluded by configuration' -ForegroundColor Yellow
    } else {
    $partitionSchemes = @($Database.PartitionSchemes | Where-Object { -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($partitionSchemes.Count -gt 0) {
        Write-Output "  Found $($partitionSchemes.Count) partition scheme(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($ps in $partitionSchemes) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $partitionSchemes.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $ps.Name)
                $fileName = Join-Path $OutputDir '05_PartitionSchemes' "$(Get-SafeFileName $($ps.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $ps.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'PartitionScheme' -ObjectName $ps.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($partitionSchemes.Count) partition scheme(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 6. User-Defined Types (UDTs, UDTTs, UDDTs)
    Write-Output ''
    Write-Output 'Exporting user-defined types...'
    if (Test-ObjectTypeExcluded -ObjectType 'UserDefinedTypes') {
        Write-Host '  [SKIPPED] UserDefinedTypes excluded by configuration' -ForegroundColor Yellow
    } else {
    $allTypes = @()
    $allTypes += @($Database.UserDefinedDataTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    $allTypes += @($Database.UserDefinedTableTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    $allTypes += @($Database.UserDefinedTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    
    if ($allTypes.Count -gt 0) {
        Write-Output "  Found $($allTypes.Count) type(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($type in $allTypes) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $allTypes.Count) * 100)
            try {
                $typeName = if ($type.Schema) { "$($type.Schema).$($type.Name)" } else { $type.Name }
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $typeName)
                $safeTypeName = Get-SafeFileName $typeName
                $fileName = Join-Path $OutputDir '06_Types' "$safeTypeName.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $type.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                $typeName = if ($type.Schema) { "$($type.Schema).$($type.Name)" } else { $type.Name }
                Write-ExportError -ObjectType 'UserDefinedType' -ObjectName $typeName -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($allTypes.Count) type(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 7. XML Schema Collections
    Write-Output ''
    Write-Output 'Exporting XML schema collections...'
    if (Test-ObjectTypeExcluded -ObjectType 'XmlSchemaCollections') {
        Write-Host '  [SKIPPED] XmlSchemaCollections excluded by configuration' -ForegroundColor Yellow
    } else {
    $xmlSchemaCollections = @($Database.XmlSchemaCollections | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($xmlSchemaCollections.Count -gt 0) {
        Write-Output "  Found $($xmlSchemaCollections.Count) XML schema collection(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($xsc in $xmlSchemaCollections) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $xmlSchemaCollections.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $xsc.Schema, $xsc.Name)
                $safeSchema = Get-SafeFileName $xsc.Schema
                $safeName = Get-SafeFileName $xsc.Name
                $fileName = Join-Path $OutputDir '07_XmlSchemaCollections' "$safeSchema.$safeName.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $xsc.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'XmlSchemaCollection' -ObjectName "$($xsc.Schema).$($xsc.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($xmlSchemaCollections.Count) XML schema collection(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 8. Tables (Primary Keys only - no FK)
    Write-Output ''
    Write-Output 'Exporting tables (PKs only)...'
    $tablesTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-ObjectTypeExcluded -ObjectType 'Tables') {
        Write-Host '  [SKIPPED] Tables excluded by configuration' -ForegroundColor Yellow
    } else {
        $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
        if ($tables.Count -gt 0) {
            Write-Output "  Found $($tables.Count) table(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
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
            $Scripter.Options = $opts
            
            foreach ($table in $tables) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $tables.Count) * 100)
                try {
                    Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name)" -Current $currentItem -Total $tables.Count
                    $fileName = Join-Path $OutputDir '08_Tables_PrimaryKey' "$(Get-SafeFileName $($table.Schema)).$(Get-SafeFileName $($table.Name)).sql"
                    Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $table.Script($opts) | Out-Null
                    Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name)" -Current $currentItem -Total $tables.Count -Success
                    $successCount++
                } catch {
                    Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name)" -Current $currentItem -Total $tables.Count -Failed
                    Write-ExportError -ObjectType 'Table' -ObjectName "$($table.Schema).$($table.Name)" -ErrorRecord $_ -AdditionalContext "Exporting table structure with primary keys"
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($tables.Count) table(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            $functionMetrics.TotalObjects += $tables.Count
            $functionMetrics.SuccessCount += $successCount
            $functionMetrics.FailCount += $failCount
        }
    }
    $tablesTimer.Stop()
    $functionMetrics.CategoryTimings['Tables'] = $tablesTimer.ElapsedMilliseconds
    
    # 9. Foreign Keys (separate from table creation)
    Write-Output ''
    Write-Output 'Exporting foreign keys...'
    if (Test-ObjectTypeExcluded -ObjectType 'ForeignKeys') {
        Write-Host '  [SKIPPED] ForeignKeys excluded by configuration' -ForegroundColor Yellow
    } else {
        # Initialize tables collection if not already defined (in case Tables were excluded)
        if (-not (Get-Variable -Name tables -Scope Local -ErrorAction SilentlyContinue)) {
            $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
        }
        
        $foreignKeys = @()
        foreach ($table in $tables) {
            try {
                # Access foreign keys collection safely
                if ($table.ForeignKeys -and $table.ForeignKeys.Count -gt 0) {
                    $foreignKeys += @($table.ForeignKeys)
                }
            } catch {
                Write-ExportError -ObjectType 'ForeignKeyCollection' -ObjectName "$($table.Schema).$($table.Name)" -ErrorRecord $_ -AdditionalContext "Accessing foreign keys collection"
            }
        }
        if ($foreignKeys.Count -gt 0) {
            Write-Output "  Found $($foreignKeys.Count) foreign key constraint(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
                DriAll            = $false
                DriForeignKeys    = $true
            }
            $Scripter.Options = $opts
            
            foreach ($fk in $foreignKeys) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $foreignKeys.Count) * 100)
                try {
                    Write-ObjectProgress -ObjectName "$($fk.Parent.Schema).$($fk.Parent.Name).$($fk.Name)" -Current $currentItem -Total $foreignKeys.Count
                    $fileName = Join-Path $OutputDir '09_Tables_ForeignKeys' "$(Get-SafeFileName $($fk.Parent.Schema)).$(Get-SafeFileName $($fk.Parent.Name)).$(Get-SafeFileName $($fk.Name)).sql"
                    Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $fk.Script($opts) | Out-Null
                    Write-ObjectProgress -ObjectName "$($fk.Parent.Schema).$($fk.Parent.Name).$($fk.Name)" -Current $currentItem -Total $foreignKeys.Count -Success
                    $successCount++
                } catch {
                    Write-ObjectProgress -ObjectName "$($fk.Parent.Schema).$($fk.Parent.Name).$($fk.Name)" -Current $currentItem -Total $foreignKeys.Count -Failed
                    Write-ExportError -ObjectType 'ForeignKey' -ObjectName "$($fk.Parent.Schema).$($fk.Parent.Name).$($fk.Name)" -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($foreignKeys.Count) foreign key constraint(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            $functionMetrics.TotalObjects += $foreignKeys.Count
            $functionMetrics.SuccessCount += $successCount
            $functionMetrics.FailCount += $failCount
        }
    }
    
    # 10. Indexes
    Write-Output ''
    Write-Output 'Exporting indexes...'
    $indexesTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-ObjectTypeExcluded -ObjectType 'Indexes') {
        Write-Host '  [SKIPPED] Indexes excluded by configuration' -ForegroundColor Yellow
    } else {
        # Initialize tables collection if not already defined (in case Tables were excluded)
        if (-not (Get-Variable -Name tables -Scope Local -ErrorAction SilentlyContinue)) {
            $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
        }
        
        $indexes = @()
        foreach ($table in $tables) {
            try {
                # Filter out indexes that are part of primary keys or unique constraints
                # These are already scripted with the table definition
                if ($table.Indexes -and $table.Indexes.Count -gt 0) {
                    $indexes += @($table.Indexes | Where-Object {
                        -not $_.IsSystemObject -and
                        -not $_.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriPrimaryKey -and
                        -not $_.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriUniqueKey
                    })
                }
            } catch {
                Write-ExportError -ObjectType 'IndexCollection' -ObjectName "$($table.Schema).$($table.Name)" -ErrorRecord $_ -AdditionalContext "Accessing indexes collection"
            }
        }
        if ($indexes.Count -gt 0) {
            Write-Output "  Found $($indexes.Count) index(es) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
                Indexes         = $true
                ClusteredIndexes = $false
                DriPrimaryKey   = $false
                DriUniqueKey    = $false
            }
            $Scripter.Options = $opts
            
            foreach ($index in $indexes) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $indexes.Count) * 100)
                try {
                    Write-ObjectProgress -ObjectName "$($index.Parent.Schema).$($index.Parent.Name).$($index.Name)" -Current $currentItem -Total $indexes.Count
                    $fileName = Join-Path $OutputDir '10_Indexes' "$(Get-SafeFileName $($index.Parent.Schema)).$(Get-SafeFileName $($index.Parent.Name)).$(Get-SafeFileName $($index.Name)).sql"
                    Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $index.Script($opts) | Out-Null
                    Write-ObjectProgress -ObjectName "$($index.Parent.Schema).$($index.Parent.Name).$($index.Name)" -Current $currentItem -Total $indexes.Count -Success
                    $successCount++
                } catch {
                    Write-ObjectProgress -ObjectName "$($index.Parent.Schema).$($index.Parent.Name).$($index.Name)" -Current $currentItem -Total $indexes.Count -Failed
                    Write-ExportError -ObjectType 'Index' -ObjectName "$($index.Parent.Schema).$($index.Parent.Name).$($index.Name)" -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($indexes.Count) index(es) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            $functionMetrics.TotalObjects += $indexes.Count
            $functionMetrics.SuccessCount += $successCount
            $functionMetrics.FailCount += $failCount
        }
    }
    $indexesTimer.Stop()
    $functionMetrics.CategoryTimings['Indexes'] = $indexesTimer.ElapsedMilliseconds
    
    # 11. Defaults
    Write-Output ''
    Write-Output 'Exporting defaults...'
    if (Test-ObjectTypeExcluded -ObjectType 'Defaults') {
        Write-Host '  [SKIPPED] Defaults excluded by configuration' -ForegroundColor Yellow
    } else {
    $defaults = @($Database.Defaults | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($defaults.Count -gt 0) {
        Write-Output "  Found $($defaults.Count) default constraint(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($default in $defaults) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $defaults.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $default.Schema, $default.Name)
                $fileName = Join-Path $OutputDir '11_Defaults' "$(Get-SafeFileName $($default.Schema)).$(Get-SafeFileName $($default.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $default.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Default' -ObjectName "$($default.Schema).$($default.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($defaults.Count) default constraint(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 12. Rules
    Write-Output ''
    Write-Output 'Exporting rules...'
    if (Test-ObjectTypeExcluded -ObjectType 'Rules') {
        Write-Host '  [SKIPPED] Rules excluded by configuration' -ForegroundColor Yellow
    } else {
    $rules = @($Database.Rules | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($rules.Count -gt 0) {
        Write-Output "  Found $($rules.Count) rule(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($rule in $rules) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $rules.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $rule.Schema, $rule.Name)
                $fileName = Join-Path $OutputDir '12_Rules' "$(Get-SafeFileName $($rule.Schema)).$(Get-SafeFileName $($rule.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $rule.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Rule' -ObjectName "$($rule.Schema).$($rule.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($rules.Count) rule(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 13. Assemblies
    Write-Output ''
    Write-Output 'Exporting assemblies...'
    if (Test-ObjectTypeExcluded -ObjectType 'Assemblies') {
        Write-Host '  [SKIPPED] Assemblies excluded by configuration' -ForegroundColor Yellow
    } else {
    $assemblies = @($Database.Assemblies | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
    if ($assemblies.Count -gt 0) {
        Write-Output "  Found $($assemblies.Count) assembly(ies) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($assembly in $assemblies) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $assemblies.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $assembly.Name)
                $fileName = Join-Path $OutputDir '13_Programmability/01_Assemblies' "$(Get-SafeFileName $($assembly.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $assembly.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Assembly' -ObjectName $assembly.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($assemblies.Count) assembly(ies) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 14. User-Defined Functions
    Write-Output ''
    Write-Output 'Exporting user-defined functions...'
    if (Test-ObjectTypeExcluded -ObjectType 'Functions') {
        Write-Host '  [SKIPPED] Functions excluded by configuration' -ForegroundColor Yellow
    } else {
    $functions = @($Database.UserDefinedFunctions | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($functions.Count -gt 0) {
        Write-Output "  Found $($functions.Count) function(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes     = $false
            Triggers    = $false
        }
        $Scripter.Options = $opts
        
        foreach ($function in $functions) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $functions.Count) * 100)
            try {
                Write-ObjectProgress -ObjectName "$($function.Schema).$($function.Name)" -Current $currentItem -Total $functions.Count
                $fileName = Join-Path $OutputDir '13_Programmability/02_Functions' "$(Get-SafeFileName $($function.Schema)).$(Get-SafeFileName $($function.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $function.Script($opts) | Out-Null
                Write-ObjectProgress -ObjectName "$($function.Schema).$($function.Name)" -Current $currentItem -Total $functions.Count -Success
                $successCount++
            } catch {
                Write-ObjectProgress -ObjectName "$($function.Schema).$($function.Name)" -Current $currentItem -Total $functions.Count -Failed
                Write-ExportError -ObjectType 'Function' -ObjectName "$($function.Schema).$($function.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($functions.Count) function(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 15. User-Defined Aggregates
    Write-Output ''
    Write-Output 'Exporting user-defined aggregates...'
    if (Test-ObjectTypeExcluded -ObjectType 'UserDefinedAggregates') {
        Write-Host '  [SKIPPED] UserDefinedAggregates excluded by configuration' -ForegroundColor Yellow
    } else {
    $aggregates = @($Database.UserDefinedAggregates | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($aggregates.Count -gt 0) {
        Write-Output "  Found $($aggregates.Count) aggregate(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($aggregate in $aggregates) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $aggregates.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $aggregate.Schema, $aggregate.Name)
                $fileName = Join-Path $OutputDir '13_Programmability/02_Functions' "$($aggregate.Schema).$($aggregate.Name).aggregate.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $aggregate.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Aggregate' -ObjectName "$($aggregate.Schema).$($aggregate.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($aggregates.Count) aggregate(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 16. Stored Procedures (including Extended Stored Procedures)
    Write-Output ''
    Write-Output 'Exporting stored procedures...'
    $procsTimer = [System.Diagnostics.Stopwatch]::StartNew()
    if (Test-ObjectTypeExcluded -ObjectType 'StoredProcedures') {
        Write-Host '  [SKIPPED] StoredProcedures excluded by configuration' -ForegroundColor Yellow
    } else {
    $storedProcs = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    $extendedProcs = @($Database.ExtendedStoredProcedures | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    $totalProcs = $storedProcs.Count + $extendedProcs.Count
    if ($totalProcs -gt 0) {
        Write-Output "  Found $($storedProcs.Count) stored procedure(s) and $($extendedProcs.Count) extended stored procedure(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Indexes  = $false
            Triggers = $false
        }
        $Scripter.Options = $opts
        
        foreach ($proc in $storedProcs) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $totalProcs) * 100)
            try {
                Write-ObjectProgress -ObjectName "$($proc.Schema).$($proc.Name)" -Current $currentItem -Total $totalProcs
                $fileName = Join-Path $OutputDir '13_Programmability/03_StoredProcedures' "$(Get-SafeFileName $($proc.Schema)).$(Get-SafeFileName $($proc.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $proc.Script($opts) | Out-Null
                Write-ObjectProgress -ObjectName "$($proc.Schema).$($proc.Name)" -Current $currentItem -Total $totalProcs -Success
                $successCount++
            } catch {
                Write-ObjectProgress -ObjectName "$($proc.Schema).$($proc.Name)" -Current $currentItem -Total $totalProcs -Failed
                Write-ExportError -ObjectType 'StoredProcedure' -ObjectName "$($proc.Schema).$($proc.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        
        foreach ($extProc in $extendedProcs) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $totalProcs) * 100)
            try {
                Write-ObjectProgress -ObjectName "$($extProc.Schema).$($extProc.Name)" -Current $currentItem -Total $totalProcs
                $fileName = Join-Path $OutputDir '13_Programmability/03_StoredProcedures' "$($extProc.Schema).$($extProc.Name).extended.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $extProc.Script($opts) | Out-Null
                Write-ObjectProgress -ObjectName "$($extProc.Schema).$($extProc.Name)" -Current $currentItem -Total $totalProcs -Success
                $successCount++
            } catch {
                Write-ObjectProgress -ObjectName "$($extProc.Schema).$($extProc.Name)" -Current $currentItem -Total $totalProcs -Failed
                Write-ExportError -ObjectType 'ExtendedStoredProcedure' -ObjectName "$($extProc.Schema).$($extProc.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$totalProcs stored procedure(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
        $functionMetrics.TotalObjects += $totalProcs
        $functionMetrics.SuccessCount += $successCount
        $functionMetrics.FailCount += $failCount
    }
    }
    $procsTimer.Stop()
    $functionMetrics.CategoryTimings['StoredProcedures'] = $procsTimer.ElapsedMilliseconds
    
    # 17. Database Triggers
    Write-Output ''
    Write-Output 'Exporting database triggers...'
    if (Test-ObjectTypeExcluded -ObjectType 'DatabaseTriggers') {
        Write-Host '  [SKIPPED] DatabaseTriggers excluded by configuration' -ForegroundColor Yellow
    } else {
    $dbTriggers = @($Database.Triggers | Where-Object { -not $_.IsSystemObject })
    if ($dbTriggers.Count -gt 0) {
        Write-Output "  Found $($dbTriggers.Count) database trigger(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            Triggers = $true
        }
        $Scripter.Options = $opts
        
        foreach ($trigger in $dbTriggers) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $dbTriggers.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $trigger.Name)
                $safeName = Get-SafeFileName $trigger.Name
                $fileName = Join-Path $OutputDir '13_Programmability/04_Triggers' "Database.$safeName.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $trigger.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'DatabaseTrigger' -ObjectName $trigger.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($dbTriggers.Count) database trigger(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 18. Table Triggers
    Write-Output ''
    Write-Output 'Exporting table triggers...'
    if (Test-ObjectTypeExcluded -ObjectType 'TableTriggers') {
        Write-Host '  [SKIPPED] TableTriggers excluded by configuration' -ForegroundColor Yellow
    } else {
    if (-not (Get-Variable -Name tables -Scope Local -ErrorAction SilentlyContinue)) {
        $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    }
    $tableTriggers = @()
    foreach ($table in $tables) {
        try {
            if ($table.Triggers -and $table.Triggers.Count -gt 0) {
                $tableTriggers += @($table.Triggers | Where-Object { -not $_.IsSystemObject })
            }
        } catch {
            Write-ExportError -ObjectType 'TriggerCollection' -ObjectName "$($table.Schema).$($table.Name)" -ErrorRecord $_ -AdditionalContext "Accessing triggers collection"
        }
    }
    if ($tableTriggers.Count -gt 0) {
        Write-Output "  Found $($tableTriggers.Count) table trigger(s) to export"
        $successCount = 0
        $failCount = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
            ClusteredIndexes = $false
            Default          = $false
            DriAll           = $false
            Indexes          = $false
            Triggers         = $true
            ScriptData       = $false
        }
        $Scripter.Options = $opts
        
        $currentItem = 0
        foreach ($trigger in $tableTriggers) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $tableTriggers.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}.{3}..." -f $percentComplete, $trigger.Parent.Schema, $trigger.Parent.Name, $trigger.Name)
                $fileName = Join-Path $OutputDir '13_Programmability/04_Triggers' "$(Get-SafeFileName $($trigger.Parent.Schema)).$(Get-SafeFileName $($trigger.Parent.Name)).$(Get-SafeFileName $($trigger.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $trigger.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'TableTrigger' -ObjectName "$($trigger.Parent.Schema).$($trigger.Parent.Name).$($trigger.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($tableTriggers.Count) table trigger(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 19. Views
    Write-Output ''
    Write-Output 'Exporting views...'
    if (Test-ObjectTypeExcluded -ObjectType 'Views') {
        Write-Host '  [SKIPPED] Views excluded by configuration' -ForegroundColor Yellow
    } else {
    $views = @($Database.Views | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($views.Count -gt 0) {
        Write-Output "  Found $($views.Count) view(s) to export"
        $successCount = 0
        $failCount = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        $currentItem = 0
        foreach ($view in $views) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $views.Count) * 100)
            try {
                Write-ObjectProgress -ObjectName "$($view.Schema).$($view.Name)" -Current $currentItem -Total $views.Count
                $fileName = Join-Path $OutputDir '13_Programmability/05_Views' "$(Get-SafeFileName $($view.Schema)).$(Get-SafeFileName $($view.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $view.Script($opts) | Out-Null
                Write-ObjectProgress -ObjectName "$($view.Schema).$($view.Name)" -Current $currentItem -Total $views.Count -Success
                $successCount++
            } catch {
                Write-ObjectProgress -ObjectName "$($view.Schema).$($view.Name)" -Current $currentItem -Total $views.Count -Failed
                Write-ExportError -ObjectType 'View' -ObjectName "$($view.Schema).$($view.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($views.Count) view(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 20. Synonyms
    Write-Output ''
    Write-Output 'Exporting synonyms...'
    if (Test-ObjectTypeExcluded -ObjectType 'Synonyms') {
        Write-Host '  [SKIPPED] Synonyms excluded by configuration' -ForegroundColor Yellow
    } else {
    $synonyms = @($Database.Synonyms | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    if ($synonyms.Count -gt 0) {
        Write-Output "  Found $($synonyms.Count) synonym(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($synonym in $synonyms) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $synonyms.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $synonym.Schema, $synonym.Name)
                $fileName = Join-Path $OutputDir '14_Synonyms' "$(Get-SafeFileName $($synonym.Schema)).$(Get-SafeFileName $($synonym.Name)).sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $synonym.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Synonym' -ObjectName "$($synonym.Schema).$($synonym.Name)" -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($synonyms.Count) synonym(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 21. Full-Text Search
    Write-Output ''
    Write-Output 'Exporting full-text search objects...'
    if (Test-ObjectTypeExcluded -ObjectType 'FullTextSearch') {
        Write-Host '  [SKIPPED] FullTextSearch excluded by configuration' -ForegroundColor Yellow
    } else {
    $ftCatalogs = @($Database.FullTextCatalogs | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Name $_.Name) })
    $ftStopLists = @($Database.FullTextStopLists | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Name $_.Name) })
    
    if ($ftCatalogs.Count -gt 0) {
        Write-Output "  Found $($ftCatalogs.Count) full-text catalog(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($ftc in $ftCatalogs) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $ftCatalogs.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $ftc.Name)
                $fileName = Join-Path $OutputDir '15_FullTextSearch' "$($ftc.Name).catalog.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $ftc.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'FullTextCatalog' -ObjectName $ftc.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($ftCatalogs.Count) full-text catalog(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($ftStopLists.Count -gt 0) {
        Write-Output "  Found $($ftStopLists.Count) full-text stop list(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($ftsl in $ftStopLists) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $ftStopLists.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $ftsl.Name)
                $fileName = Join-Path $OutputDir '15_FullTextSearch' "$($ftsl.Name).stoplist.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $ftsl.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'FullTextStopList' -ObjectName $ftsl.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($ftStopLists.Count) full-text stop list(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 22. External Data Sources and File Formats
    Write-Output ''
    Write-Output 'Exporting external data sources and file formats...'
    if (Test-ObjectTypeExcluded -ObjectType 'ExternalData') {
        Write-Host '  [SKIPPED] ExternalData excluded by configuration' -ForegroundColor Yellow
    } else {
    try {
        $externalDataSources = @($Database.ExternalDataSources)
        $externalFileFormats = @($Database.ExternalFileFormats)
        
        if ($externalDataSources.Count -gt 0) {
            Write-Output "  Found $($externalDataSources.Count) external data source(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $Scripter.Options = $opts
            
            foreach ($eds in $externalDataSources) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $externalDataSources.Count) * 100)
                try {
                    Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $eds.Name)
                    $fileName = Join-Path $OutputDir '16_ExternalData' "$($eds.Name).datasource.sql"
                Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $eds.Script($opts) | Out-Null
                    Write-Host "        [SUCCESS]" -ForegroundColor Green
                    $successCount++
                } catch {
                    Write-Host "        [FAILED]" -ForegroundColor Red
                    Write-ExportError -ObjectType 'ExternalDataSource' -ObjectName $eds.Name -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($externalDataSources.Count) external data source(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            Write-Output "  [INFO] External data sources contain environment-specific connection strings"
        }
        
        if ($externalFileFormats.Count -gt 0) {
            Write-Output "  Found $($externalFileFormats.Count) external file format(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $Scripter.Options = $opts
            
            foreach ($eff in $externalFileFormats) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $externalFileFormats.Count) * 100)
                try {
                    Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $eff.Name)
                    $fileName = Join-Path $OutputDir '16_ExternalData' "$($eff.Name).fileformat.sql"
                Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $eff.Script($opts) | Out-Null
                    Write-Host "        [SUCCESS]" -ForegroundColor Green
                    $successCount++
                } catch {
                    Write-Host "        [FAILED]" -ForegroundColor Red
                    Write-ExportError -ObjectType 'ExternalFileFormat' -ObjectName $eff.Name -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($externalFileFormats.Count) external file format(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
        }
        
        if ($externalDataSources.Count -eq 0 -and $externalFileFormats.Count -eq 0) {
            Write-Output "  [INFO] No external data sources or file formats found"
        }
    } catch {
        Write-Output "  [INFO] External data objects not available (SQL Server 2016+ with PolyBase)"
    }
    }
    
    # 23. Search Property Lists
    Write-Output ''
    Write-Output 'Exporting search property lists...'
    if (Test-ObjectTypeExcluded -ObjectType 'SearchPropertyLists') {
        Write-Host '  [SKIPPED] SearchPropertyLists excluded by configuration' -ForegroundColor Yellow
    } else {
    try {
        $searchPropertyLists = @($Database.SearchPropertyLists)
        if ($searchPropertyLists.Count -gt 0) {
            Write-Output "  Found $($searchPropertyLists.Count) search property list(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $Scripter.Options = $opts
            
            foreach ($spl in $searchPropertyLists) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $searchPropertyLists.Count) * 100)
                try {
                    Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $spl.Name)
                    $fileName = Join-Path $OutputDir '17_SearchPropertyLists' "$(Get-SafeFileName $($spl.Name)).sql"
                Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $spl.Script($opts) | Out-Null
                    Write-Host "        [SUCCESS]" -ForegroundColor Green
                    $successCount++
                } catch {
                    Write-Host "        [FAILED]" -ForegroundColor Red
                    Write-ExportError -ObjectType 'SearchPropertyList' -ObjectName $spl.Name -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($searchPropertyLists.Count) search property list(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
        } else {
            Write-Output "  [INFO] No search property lists found"
        }
    } catch {
        Write-Output "  [INFO] Search property lists not available (SQL Server 2008+)"
    }
    }
    
    # 24. Plan Guides
    Write-Output ''
    Write-Output 'Exporting plan guides...'
    if (Test-ObjectTypeExcluded -ObjectType 'PlanGuides') {
        Write-Host '  [SKIPPED] PlanGuides excluded by configuration' -ForegroundColor Yellow
    } else {
    try {
        $planGuides = @($Database.PlanGuides)
        if ($planGuides.Count -gt 0) {
            Write-Output "  Found $($planGuides.Count) plan guide(s) to export"
            $successCount = 0
            $failCount = 0
            $currentItem = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $Scripter.Options = $opts
            
            foreach ($pg in $planGuides) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $planGuides.Count) * 100)
                try {
                    Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $pg.Name)
                    $fileName = Join-Path $OutputDir '18_PlanGuides' "$(Get-SafeFileName $($pg.Name)).sql"
                Ensure-DirectoryExists $fileName
                    $opts.FileName = $fileName
                    $Scripter.Options = $opts
                    $pg.Script($opts) | Out-Null
                    Write-Host "        [SUCCESS]" -ForegroundColor Green
                    $successCount++
                } catch {
                    Write-Host "        [FAILED]" -ForegroundColor Red
                    Write-ExportError -ObjectType 'PlanGuide' -ObjectName $pg.Name -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($planGuides.Count) plan guide(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            Write-Output "  [INFO] Plan guides may need adjustment for target environment query patterns"
        } else {
            Write-Output "  [INFO] No plan guides found"
        }
    } catch {
        Write-Output "  [INFO] Plan guides not available"
    }
    }
    
    # 25. Security Objects (Keys, Certificates, Roles, Users, Audit)
    Write-Output ''
    Write-Output 'Exporting security objects...'
    if (Test-ObjectTypeExcluded -ObjectType 'Security') {
        Write-Host '  [SKIPPED] Security objects excluded by configuration' -ForegroundColor Yellow
    } else {
    $asymmetricKeys = @($Database.AsymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $certs = @($Database.Certificates | Where-Object { -not $_.IsSystemObject })
    $symKeys = @($Database.SymmetricKeys | Where-Object { -not $_.IsSystemObject })
    $appRoles = @($Database.ApplicationRoles | Where-Object { -not $_.IsSystemObject })
    $dbRoles = @($Database.Roles | Where-Object { -not $_.IsSystemObject -and -not $_.IsFixedRole })
    $dbUsers = @($Database.Users | Where-Object { -not $_.IsSystemObject })
    $auditSpecs = @($Database.DatabaseAuditSpecifications)
    
    if ($asymmetricKeys.Count -gt 0) {
        Write-Output "  Found $($asymmetricKeys.Count) asymmetric key(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($key in $asymmetricKeys) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $asymmetricKeys.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $key.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($key.Name).asymmetrickey.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $key.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'AsymmetricKey' -ObjectName $key.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($asymmetricKeys.Count) asymmetric key(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($certs.Count -gt 0) {
        Write-Output "  Found $($certs.Count) certificate(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($cert in $certs) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $certs.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $cert.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($cert.Name).certificate.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $cert.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'Certificate' -ObjectName $cert.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($certs.Count) certificate(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($symKeys.Count -gt 0) {
        Write-Output "  Found $($symKeys.Count) symmetric key(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($key in $symKeys) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $symKeys.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $key.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($key.Name).symmetrickey.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $key.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'SymmetricKey' -ObjectName $key.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($symKeys.Count) symmetric key(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($appRoles.Count -gt 0) {
        Write-Output "  Found $($appRoles.Count) application role(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($role in $appRoles) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $appRoles.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $role.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($role.Name).approle.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $role.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'ApplicationRole' -ObjectName $role.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($appRoles.Count) application role(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($dbRoles.Count -gt 0) {
        Write-Output "  Found $($dbRoles.Count) database role(s) to export"
        $successCount = 0
        $failCount = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        $currentItem = 0
        foreach ($role in $dbRoles) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $dbRoles.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $role.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($role.Name).role.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $role.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'DatabaseRole' -ObjectName $role.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($dbRoles.Count) database role(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($dbUsers.Count -gt 0) {
        Write-Output "  Found $($dbUsers.Count) database user(s) to export"
        $successCount = 0
        $failCount = 0
        $currentItem = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        foreach ($user in $dbUsers) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $dbUsers.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $user.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($user.Name).user.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $user.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'DatabaseUser' -ObjectName $user.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($dbUsers.Count) database user(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    
    if ($auditSpecs.Count -gt 0) {
        Write-Output "  Found $($auditSpecs.Count) database audit specification(s) to export"
        $successCount = 0
        $failCount = 0
        $opts = New-ScriptingOptions -TargetVersion $TargetVersion
        $Scripter.Options = $opts
        
        $currentItem = 0
        foreach ($spec in $auditSpecs) {
            $currentItem++
            $percentComplete = [math]::Round(($currentItem / $auditSpecs.Count) * 100)
            try {
                Write-Host ("  [{0,3}%]{1}..." -f $percentComplete, $spec.Name)
                $fileName = Join-Path $OutputDir '19_Security' "$($spec.Name).auditspec.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $spec.Script($opts) | Out-Null
                Write-Host "        [SUCCESS]" -ForegroundColor Green
                $successCount++
            } catch {
                Write-Host "        [FAILED]" -ForegroundColor Red
                Write-ExportError -ObjectType 'DatabaseAuditSpecification' -ObjectName $spec.Name -ErrorRecord $_ -FilePath $fileName
                $failCount++
            }
        }
        Write-Output "  [SUMMARY] Exported $successCount/$($auditSpecs.Count) database audit specification(s) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
    }
    }
    
    # 26. Security Policies (Row-Level Security)
    Write-Output ''
    Write-Output 'Exporting security policies (Row-Level Security)...'
    if (Test-ObjectTypeExcluded -ObjectType 'SecurityPolicies') {
        Write-Host '  [SKIPPED] SecurityPolicies excluded by configuration' -ForegroundColor Yellow
    } else {
    try {
        $securityPolicies = @($Database.SecurityPolicies)
        if ($securityPolicies.Count -gt 0) {
            Write-Output "  Found $($securityPolicies.Count) security policy(ies) to export"
            $successCount = 0
            $failCount = 0
            $opts = New-ScriptingOptions -TargetVersion $TargetVersion
            $Scripter.Options = $opts
            
            $currentItem = 0
            foreach ($policy in $securityPolicies) {
                $currentItem++
                $percentComplete = [math]::Round(($currentItem / $securityPolicies.Count) * 100)
                try {
                    Write-Host ("  [{0,3}%]{1}.{2}..." -f $percentComplete, $policy.Schema, $policy.Name)
                    $fileName = Join-Path $OutputDir '19_Security' "$($policy.Schema).$($policy.Name).securitypolicy.sql"
                Ensure-DirectoryExists $fileName
                    
                    # Create file with header
                    $policyScript = New-Object System.Text.StringBuilder
                    [void]$policyScript.AppendLine("-- Row-Level Security Policy: $($policy.Schema).$($policy.Name)")
                    [void]$policyScript.AppendLine("-- NOTE: Ensure predicate functions are created before applying this policy")
                    [void]$policyScript.AppendLine("")
                    
                    $policyDef = $Scripter.Script($policy)
                    [void]$policyScript.AppendLine($policyDef -join "`n")
                    [void]$policyScript.AppendLine("GO")
                    
                    $policyScript.ToString() | Out-File -FilePath $fileName -Encoding UTF8
                    Write-Host "        [SUCCESS]" -ForegroundColor Green
                    $successCount++
                } catch {
                    Write-Host "        [FAILED]" -ForegroundColor Red
                    Write-ExportError -ObjectType 'SecurityPolicy' -ObjectName "$($policy.Schema).$($policy.Name)" -ErrorRecord $_ -FilePath $fileName
                    $failCount++
                }
            }
            Write-Output "  [SUMMARY] Exported $successCount/$($securityPolicies.Count) security policy(ies) successfully" + $(if ($failCount -gt 0) { " ($failCount failed)" } else { "" })
            Write-Output "  [INFO] Row-Level Security policies require predicate functions to exist first"
        } else {
            Write-Output "  [INFO] No security policies found"
        }
    } catch {
        Write-Output "  [INFO] Security policies not available (SQL Server 2016+)"
    }
    }
    
    # Return metrics summary
    return $functionMetrics
}

function Export-TableData {
    <#
    .SYNOPSIS
        Exports table data as INSERT statements.
    .OUTPUTS
        Returns a hashtable with TablesWithData, SuccessCount, FailCount, and EmptyCount for metrics.
    #>
    param(
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        [string]$OutputDir,
        [Microsoft.SqlServer.Management.Smo.Scripter]$Scripter,
        [Microsoft.SqlServer.Management.Smo.SqlServerVersion]$TargetVersion
    )
    
    # Initialize metrics tracking for this function
    $dataMetrics = @{
        TablesWithData = 0
        SuccessCount = 0
        FailCount = 0
        EmptyCount = 0
        TotalRows = 0
    }
    
    Write-Output ''
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORTING TABLE DATA'
    Write-Output '═══════════════════════════════════════════════'
    
    $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
    
    if ($tables.Count -eq 0) {
        Write-Output 'No tables found.'
        return $dataMetrics
    }
    
    Write-Output "  Found $($tables.Count) table(s) to check for data export"
    
    # OPTIMIZATION: Get all row counts in a single query instead of per-table COUNT(*)
    # This reduces N database round-trips to just 1
    Write-Output "  Fetching row counts for all tables..."
    $rowCountQuery = @"
SELECT 
    s.name AS SchemaName,
    t.name AS TableName,
    SUM(p.rows) AS TableRowCount
FROM sys.tables t
INNER JOIN sys.schemas s ON t.schema_id = s.schema_id
INNER JOIN sys.partitions p ON t.object_id = p.object_id
WHERE p.index_id IN (0, 1)  -- Heap or clustered index
  AND t.is_ms_shipped = 0
GROUP BY s.name, t.name
"@
    $rowCountData = $Database.ExecuteWithResults($rowCountQuery)
    $rowCountLookup = @{}
    foreach ($row in $rowCountData.Tables[0].Rows) {
        $key = "$($row.SchemaName).$($row.TableName)"
        $rowCountLookup[$key] = [long]$row.TableRowCount
    }
    Write-Output "  [SUCCESS] Retrieved row counts for $($rowCountLookup.Count) table(s)"
    
    $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
        ScriptSchema = $false
        ScriptData   = $true
    }
    $Scripter.Options = $opts
    
    $successCount = 0
    $failCount = 0
    $emptyCount = 0
    
    $currentItem = 0
    foreach ($table in $tables) {
        $currentItem++
        $percentComplete = [math]::Round(($currentItem / $tables.Count) * 100)
        try {
            # Look up row count from pre-fetched data (no network round-trip)
            $tableKey = "$($table.Schema).$($table.Name)"
            $rowCount = if ($rowCountLookup.ContainsKey($tableKey)) { $rowCountLookup[$tableKey] } else { 0 }
            
            if ($rowCount -gt 0) {
                Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name) ($rowCount row(s))" -Current $currentItem -Total $tables.Count
                $fileName = Join-Path $OutputDir '20_Data' "$($table.Schema).$($table.Name).data.sql"
                Ensure-DirectoryExists $fileName
                $opts.FileName = $fileName
                $Scripter.Options = $opts
                $Scripter.EnumScript($table) | Out-Null
                Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name)" -Current $currentItem -Total $tables.Count -Success
                $successCount++
            } else {
                $emptyCount++
            }
        } catch {
            Write-ObjectProgress -ObjectName "$($table.Schema).$($table.Name)" -Current $currentItem -Total $tables.Count -Failed
            Write-ExportError -ObjectType 'TableData' -ObjectName "$($table.Schema).$($table.Name)" -ErrorRecord $_ -AdditionalContext "Exporting $rowCount row(s)"
            $failCount++
        }
    }
    
    Write-Output "  [SUMMARY] Exported data from $successCount/$($tables.Count) table(s) successfully"
    if ($emptyCount -gt 0) {
        Write-Output "  [INFO] Skipped $emptyCount empty table(s)"
    }
    if ($failCount -gt 0) {
        Write-Output "  [WARNING] Failed to export data from $failCount table(s)"
    }
    
    # Return metrics summary
    $dataMetrics.TablesWithData = $successCount + $failCount
    $dataMetrics.SuccessCount = $successCount
    $dataMetrics.FailCount = $failCount
    $dataMetrics.EmptyCount = $emptyCount
    return $dataMetrics
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
    # Initialize metrics collection
    $script:CollectMetrics = $CollectMetrics.IsPresent
    if ($script:CollectMetrics) {
        $script:Metrics.StartTime = Get-Date
        Write-Output '[INFO] Performance metrics collection enabled'
    }
    
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
    
    # Validate dependencies
    Test-Dependencies
    
    # Test database connection
    if (-not (Test-DatabaseConnection -ServerName $Server -DatabaseName $Database -Cred $Credential -Config $config -Timeout $effectiveConnectionTimeout)) {
        exit 1
    }
    
    # Initialize output directory
    $exportDir = Initialize-OutputDirectory -Path $OutputPath
    
    # Initialize log file
    $script:LogFile = Join-Path $exportDir 'export-log.txt'
    Write-Log "Export started" -Severity INFO
    Write-Log "Server: $Server" -Severity INFO
    Write-Log "Database: $Database" -Severity INFO
    Write-Log "Output: $exportDir" -Severity INFO
    Write-Log "Configuration source: $configSource" -Severity INFO
    
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
    $connectionTimer = Start-MetricsTimer -Category 'Connection'
    
    $smServer = $null
    if ($Credential) {
        $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
        $smServer.ConnectionContext.LoginSecure = $false
        $smServer.ConnectionContext.Login = $Credential.UserName
        $smServer.ConnectionContext.SecurePassword = $Credential.Password
    } else {
        $smServer = [Microsoft.SqlServer.Management.Smo.Server]::new($Server)
    }
    
    $smServer.ConnectionContext.ConnectTimeout = $effectiveConnectionTimeout
    
    # Apply TrustServerCertificate from config if specified
    if ($config -and $config.ContainsKey('trustServerCertificate')) {
        $smServer.ConnectionContext.TrustServerCertificate = $config.trustServerCertificate
    }
    
    # Connect with retry logic
    try {
        Invoke-WithRetry -MaxAttempts $effectiveMaxRetries -InitialDelaySeconds $effectiveRetryDelay -OperationName "SQL Server Connection" -ScriptBlock {
            $smServer.ConnectionContext.Connect()
            
            # Validate connection by attempting to read server version
            $null = $smServer.Version
        }
    } catch {
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
   - Add to your config file: trustServerCertificate: true
   - WARNING: This disables server identity verification and allows
     man-in-the-middle attacks. Use ONLY in isolated dev environments.

For more details, see: https://go.microsoft.com/fwlink/?linkid=2226722
"@
        }
        throw
    }
    
    $smDatabase = $smServer.Databases[$Database]
    if ($null -eq $smDatabase) {
        throw "Database '$Database' not found"
    }
    
    Write-Output "[SUCCESS] Connected to $Server\$Database"
    Write-Log "Connected successfully to $Server\$Database" -Severity INFO
    
    # Record connection time
    if ($connectionTimer) {
        $connectionTimer.Stop()
        $script:Metrics.ConnectionTimeMs = $connectionTimer.ElapsedMilliseconds
    }
    
    # ═══════════════════════════════════════════════════════════════════════════
    # PHASE 2 OPTIMIZATION: SMO Prefetch with SetDefaultInitFields
    # ═══════════════════════════════════════════════════════════════════════════
    # By default, SMO uses lazy loading - each property access triggers a query.
    # SetDefaultInitFields tells SMO to prefetch all properties in bulk
    # when collections are first accessed, eliminating N+1 query problems.
    # ═══════════════════════════════════════════════════════════════════════════
    Write-Output "Initializing SMO property prefetch..."
    
    # Prefetch ALL properties for commonly used types - more aggressive but simpler
    # This trades slightly more memory for significantly fewer SQL round-trips
    $typesToPrefetch = @(
        [Microsoft.SqlServer.Management.Smo.Table],
        [Microsoft.SqlServer.Management.Smo.Column],
        [Microsoft.SqlServer.Management.Smo.Index],
        [Microsoft.SqlServer.Management.Smo.ForeignKey],
        [Microsoft.SqlServer.Management.Smo.StoredProcedure],
        [Microsoft.SqlServer.Management.Smo.View],
        [Microsoft.SqlServer.Management.Smo.UserDefinedFunction],
        [Microsoft.SqlServer.Management.Smo.Trigger],
        [Microsoft.SqlServer.Management.Smo.Schema],
        [Microsoft.SqlServer.Management.Smo.UserDefinedType],
        [Microsoft.SqlServer.Management.Smo.UserDefinedTableType],
        [Microsoft.SqlServer.Management.Smo.Synonym],
        [Microsoft.SqlServer.Management.Smo.Sequence]
    )
    
    foreach ($smoType in $typesToPrefetch) {
        try {
            $smServer.SetDefaultInitFields($smoType, $true)
        } catch {
            # Some types may not be available on all SQL Server versions - continue
            Write-Log "Could not set prefetch for $($smoType.Name): $_" -Severity WARNING
        }
    }
    
    Write-Output "[SUCCESS] SMO prefetch configured for $($typesToPrefetch.Count) object types"
    
    # Create scripter
    # Resolve target SQL Server version
    
    try {
        $sqlVersion = Get-SqlServerVersion -VersionString $TargetSqlVersion
    }
    catch {
        throw
    }
    
    if ($null -eq $sqlVersion) {
        throw "Get-SqlServerVersion returned null for TargetSqlVersion '$TargetSqlVersion'"
    }
    
    $scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($smServer)
    $scripter.Options.TargetServerVersion = $sqlVersion
    
    # Export schema objects with timing
    $schemaTimer = Start-MetricsTimer -Category 'SchemaExport'
    Write-Output "═══════════════════════════════════════════════════════════════"
    $schemaResult = Export-DatabaseObjects -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
    if ($schemaTimer) {
        $schemaTimer.Stop()
        $script:Metrics.Categories['SchemaExport'] = @{
            DurationMs = $schemaTimer.ElapsedMilliseconds
            ObjectCount = if ($schemaResult) { $schemaResult.TotalObjects } else { 0 }
            SuccessCount = if ($schemaResult) { $schemaResult.SuccessCount } else { 0 }
            FailCount = if ($schemaResult) { $schemaResult.FailCount } else { 0 }
            AvgMsPerObject = 0
        }
    }
    
    # Export data if requested with timing
    if ($IncludeData) {
        $dataTimer = Start-MetricsTimer -Category 'DataExport'
        $dataResult = Export-TableData -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
        if ($dataTimer) {
            $dataTimer.Stop()
            $script:Metrics.Categories['DataExport'] = @{
                DurationMs = $dataTimer.ElapsedMilliseconds
                ObjectCount = if ($dataResult) { $dataResult.TablesWithData } else { 0 }
                SuccessCount = if ($dataResult) { $dataResult.SuccessCount } else { 0 }
                FailCount = if ($dataResult) { $dataResult.FailCount } else { 0 }
                AvgMsPerObject = 0
            }
        }
    }
    
    # Create deployment manifest
    New-DeploymentManifest -OutputDir $exportDir -DatabaseName $Database -ServerName $Server
    
    # Show export summary
    Show-ExportSummary -OutputDir $exportDir -DatabaseName $Database -ServerName $Server -DataExported $IncludeData
    
    # Save performance metrics if collection enabled
    Save-PerformanceMetrics -OutputDir $exportDir
    
    Write-Output '═══════════════════════════════════════════════'
    Write-Output 'EXPORT COMPLETE'
    Write-Output '═══════════════════════════════════════════════'
    Write-Output ''
    Write-Log "Export completed successfully" -Severity INFO
    
} catch {
    Write-Error "[ERROR] Script failed: $_"
    Write-Log "Script failed: $_" -Severity ERROR
    exit 1
} finally {
    # Ensure database connection is closed
    if ($smServer -and $smServer.ConnectionContext.IsOpen) {
        Write-Output 'Disconnecting from SQL Server...'
        $smServer.ConnectionContext.Disconnect()
        Write-Log "Disconnected from SQL Server" -Severity INFO
    }
}

exit 0