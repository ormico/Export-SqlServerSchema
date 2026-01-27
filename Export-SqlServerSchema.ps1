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

.PARAMETER Parallel
    Enable parallel export processing using multiple worker threads. Can also be enabled via
    YAML config (export.parallel.enabled: true). Command-line switch overrides config file.

.PARAMETER MaxWorkers
    Maximum number of parallel workers (1-20, default: 5). Only applies when -Parallel is enabled.
    Overrides YAML config setting (export.parallel.maxWorkers). Higher values may improve performance
    on large databases but increase memory usage.

.EXAMPLE
    # Export with Windows auth
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb

    # Export with SQL auth
    $cred = Get-Credential
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb -Credential $cred

    # Export with data
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb -IncludeData -OutputPath ./exports

    # Export with parallel processing
    ./Export-SqlServerSchema.ps1 -Server localhost -Database TestDb -Parallel -MaxWorkers 8

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
  [switch]$CollectMetrics,

  [Parameter(HelpMessage = 'Include only specific object types (overrides config file). Example: Tables,Views,StoredProcedures')]
  [ValidateSet('FileGroups', 'DatabaseScopedConfigurations', 'DatabaseScopedCredentials', 'Schemas', 'Sequences',
    'PartitionFunctions', 'PartitionSchemes', 'UserDefinedTypes', 'XmlSchemaCollections', 'Tables',
    'ForeignKeys', 'Indexes', 'Defaults', 'Rules', 'Assemblies', 'DatabaseTriggers', 'TableTriggers',
    'Functions', 'UserDefinedAggregates', 'StoredProcedures', 'Views', 'Synonyms', 'FullTextCatalogs',
    'FullTextStopLists', 'SearchPropertyLists', 'ExternalDataSources', 'ExternalFileFormats',
    'DatabaseRoles', 'DatabaseUsers', 'Certificates', 'AsymmetricKeys', 'SymmetricKeys',
    'SecurityPolicies', 'PlanGuides', 'Data')]
  [string[]]$IncludeObjectTypes,

  [Parameter(HelpMessage = 'Exclude specific object types (overrides config file). Example: Data,SecurityPolicies')]
  [ValidateSet('FileGroups', 'DatabaseScopedConfigurations', 'DatabaseScopedCredentials', 'Schemas', 'Sequences',
    'PartitionFunctions', 'PartitionSchemes', 'UserDefinedTypes', 'XmlSchemaCollections', 'Tables',
    'ForeignKeys', 'Indexes', 'Defaults', 'Rules', 'Assemblies', 'DatabaseTriggers', 'TableTriggers',
    'Functions', 'UserDefinedAggregates', 'StoredProcedures', 'Views', 'Synonyms', 'FullTextCatalogs',
    'FullTextStopLists', 'SearchPropertyLists', 'ExternalDataSources', 'ExternalFileFormats',
    'DatabaseRoles', 'DatabaseUsers', 'Certificates', 'AsymmetricKeys', 'SymmetricKeys',
    'SecurityPolicies', 'PlanGuides', 'Data')]
  [string[]]$ExcludeObjectTypes,

  [Parameter(HelpMessage = 'Enable parallel export processing for improved performance')]
  [switch]$Parallel,

  [Parameter(HelpMessage = 'Maximum number of parallel workers (1-20, default: 5). Overrides config file.')]
  [ValidateRange(1, 20)]
  [int]$MaxWorkers = 0,

  [Parameter(HelpMessage = 'Path to previous export for delta/incremental export. Only changed objects will be re-exported.')]
  [string]$DeltaFrom
)

$ErrorActionPreference = 'Stop'

# Early module load - required for SMO type resolution in function definitions
try {
  $sqlModule = Get-Module -ListAvailable -Name SqlServer | Sort-Object Version -Descending | Select-Object -First 1
  if ($sqlModule) {
    Import-Module SqlServer -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
  }
}
catch {
  # Will be handled properly in Test-Dependencies
}

# Parallel code consolidated below


#region PARALLEL EXPORT FUNCTIONS
# All parallel export functionality consolidated from separate files
# ~2,400 lines for parallel processing infrastructure


# === From parallel-implementation.ps1 ===



$script:ParallelWorkerScriptBlock = {
  param(
    [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$WorkQueue,
    [ref]$ProgressCounter,
    [System.Collections.Concurrent.ConcurrentBag[hashtable]]$ResultsBag,
    [hashtable]$ConnectionInfo,
    [string]$TargetVersion
  )

  #region Worker Setup
  try {
    # Create own SMO connection
    $serverConn = [Microsoft.SqlServer.Management.Common.ServerConnection]::new($ConnectionInfo.ServerName)

    if ($ConnectionInfo.UseIntegratedSecurity) {
      $serverConn.LoginSecure = $true
    }
    else {
      $serverConn.LoginSecure = $false
      $serverConn.Login = $ConnectionInfo.Username
      $serverConn.SecurePassword = $ConnectionInfo.SecurePassword
    }

    if ($ConnectionInfo.TrustServerCertificate) {
      $serverConn.TrustServerCertificate = $true
    }

    $serverConn.ConnectTimeout = $ConnectionInfo.ConnectTimeout
    $serverConn.Connect()

    $server = [Microsoft.SqlServer.Management.Smo.Server]::new($serverConn)
    $db = $server.Databases[$ConnectionInfo.DatabaseName]

    if (-not $db) {
      throw "Database '$($ConnectionInfo.DatabaseName)' not found"
    }

    # Create Scripter with prefetch enabled
    $scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($server)
    $scripter.PrefetchObjects = $true
  }
  catch {
    # Fatal setup error - can't process any work items
    $ResultsBag.Add(@{
        WorkItemId  = [guid]::Empty
        Success     = $false
        ObjectCount = 0
        Error       = "Worker setup failed: $($_.Exception.Message)"
        ObjectType  = 'WorkerSetup'
        Objects     = @()
      })
    return
  }
  #endregion

  #region Work Loop
  while ($true) {
    $workItem = $null
    if (-not $WorkQueue.TryDequeue([ref]$workItem)) {
      break  # No more work items
    }

    $result = @{
      WorkItemId  = $workItem.WorkItemId
      Success     = $false
      ObjectCount = $workItem.Objects.Count
      Error       = $null
      ObjectType  = $workItem.ObjectType
      Objects     = $workItem.Objects
    }

    try {
      # Ensure output directory exists (handle race condition with concurrent workers)
      $outputDir = Split-Path -Parent $workItem.OutputPath
      if (-not (Test-Path $outputDir)) {
        try {
          New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }
        catch {
          # Race condition: another worker may have created it between Test-Path and New-Item
          if (-not (Test-Path $outputDir)) {
            throw  # Re-throw if directory still doesn't exist (actual error)
          }
          # Otherwise, directory was created by another worker - continue
        }
      }

      # Fetch SMO objects by identifier
      $smoObjects = [System.Collections.Generic.List[object]]::new()

      foreach ($objId in $workItem.Objects) {
        $smoObj = $null

        # Handle special object types
        if ($workItem.SpecialHandler -eq 'Indexes') {
          # For indexes, fetch the individual index object from the parent table
          $table = $db.Tables[$objId.TableName, $objId.TableSchema]
          if ($table -and $table.Indexes) {
            $smoObj = $table.Indexes[$objId.IndexName]
          }
        }
        elseif ($workItem.SpecialHandler -eq 'ForeignKeys') {
          # For foreign keys, fetch individual FK or parent table depending on grouping mode
          $table = $db.Tables[$objId.Name, $objId.Schema]
          if ($table -and $objId.FKName -and $workItem.GroupingMode -eq 'single') {
            # Single mode: fetch individual FK object
            $smoObj = $table.ForeignKeys[$objId.FKName]
          }
          elseif ($table) {
            # Grouped mode: return table for FK scripting options
            $smoObj = $table
          }
        }
        elseif ($workItem.SpecialHandler -eq 'TableTriggers') {
          # For triggers, fetch individual trigger or parent table depending on grouping mode
          $table = $db.Tables[$objId.Name, $objId.Schema]
          if ($table -and $objId.TriggerName -and $workItem.GroupingMode -eq 'single') {
            # Single mode: fetch individual trigger object
            $smoObj = $table.Triggers[$objId.TriggerName]
          }
          elseif ($table) {
            # Grouped mode: return table for trigger scripting options
            $smoObj = $table
          }
        }
        elseif ($workItem.ObjectType -eq 'TableData') {
          # For TableData, fetch the table object (data scripting options are set separately)
          $smoObj = $db.Tables[$objId.Name, $objId.Schema]
        }
        else {
          # Standard object lookup
          switch ($workItem.ObjectType) {
            'Table' { $smoObj = $db.Tables[$objId.Name, $objId.Schema] }
            'View' { $smoObj = $db.Views[$objId.Name, $objId.Schema] }
            'StoredProcedure' { $smoObj = $db.StoredProcedures[$objId.Name, $objId.Schema] }
            'UserDefinedFunction' { $smoObj = $db.UserDefinedFunctions[$objId.Name, $objId.Schema] }
            'Schema' { $smoObj = $db.Schemas[$objId.Name] }
            'Sequence' { $smoObj = $db.Sequences[$objId.Name, $objId.Schema] }
            'Synonym' { $smoObj = $db.Synonyms[$objId.Name, $objId.Schema] }
            'UserDefinedType' { $smoObj = $db.UserDefinedTypes[$objId.Name, $objId.Schema] }
            'UserDefinedDataType' { $smoObj = $db.UserDefinedDataTypes[$objId.Name, $objId.Schema] }
            'UserDefinedTableType' { $smoObj = $db.UserDefinedTableTypes[$objId.Name, $objId.Schema] }
            'XmlSchemaCollection' { $smoObj = $db.XmlSchemaCollections[$objId.Name, $objId.Schema] }
            'PartitionFunction' { $smoObj = $db.PartitionFunctions[$objId.Name] }
            'PartitionScheme' { $smoObj = $db.PartitionSchemes[$objId.Name] }
            'Default' { $smoObj = $db.Defaults[$objId.Name, $objId.Schema] }
            'Rule' { $smoObj = $db.Rules[$objId.Name, $objId.Schema] }
            'DatabaseTrigger' { $smoObj = $db.Triggers[$objId.Name] }
            'FullTextCatalog' { $smoObj = $db.FullTextCatalogs[$objId.Name] }
            'FullTextStopList' { $smoObj = $db.FullTextStopLists[$objId.Name] }
            'SearchPropertyList' { $smoObj = $db.SearchPropertyLists[$objId.Name] }
            'SecurityPolicy' { $smoObj = $db.SecurityPolicies[$objId.Name, $objId.Schema] }
            'AsymmetricKey' { $smoObj = $db.AsymmetricKeys[$objId.Name] }
            'Certificate' { $smoObj = $db.Certificates[$objId.Name] }
            'SymmetricKey' { $smoObj = $db.SymmetricKeys[$objId.Name] }
            'ApplicationRole' { $smoObj = $db.ApplicationRoles[$objId.Name] }
            'DatabaseRole' { $smoObj = $db.Roles[$objId.Name] }
            'User' { $smoObj = $db.Users[$objId.Name] }
            'PlanGuide' { $smoObj = $db.PlanGuides[$objId.Name] }
            'ExternalDataSource' { $smoObj = $db.ExternalDataSources[$objId.Name] }
            'ExternalFileFormat' { $smoObj = $db.ExternalFileFormats[$objId.Name] }
            'UserDefinedAggregate' { $smoObj = $db.UserDefinedAggregates[$objId.Name, $objId.Schema] }
            'SqlAssembly' { $smoObj = $db.Assemblies[$objId.Name] }
          }
        }

        if ($smoObj) {
          $smoObjects.Add($smoObj)
        }
      }

      if ($smoObjects.Count -eq 0) {
        throw "No SMO objects found for work item"
      }

      # Configure scripting options
      $scripter.Options = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
      $scripter.Options.ToFileOnly = $true
      $scripter.Options.FileName = $workItem.OutputPath
      $scripter.Options.AppendToFile = $workItem.AppendToFile
      $scripter.Options.AnsiFile = $true
      $scripter.Options.IncludeHeaders = $false  # Match sequential export (no date-stamped headers)
      $scripter.Options.NoCollation = $true       # Match sequential export (omit explicit collation)
      $scripter.Options.ScriptBatchTerminator = $true
      $scripter.Options.TargetServerVersion = $TargetVersion

      # Apply custom scripting options from work item
      foreach ($optKey in $workItem.ScriptingOptions.Keys) {
        try {
          $scripter.Options.$optKey = $workItem.ScriptingOptions[$optKey]
        }
        catch {
          # Ignore invalid options
        }
      }

      # Handle special cases
      if ($workItem.SpecialHandler -eq 'SecurityPolicy') {
        # Write custom header first (matching sequential format)
        # Build the full name from the Objects array
        $policyName = if ($workItem.Objects.Count -gt 0) {
          "$($workItem.Objects[0].Schema).$($workItem.Objects[0].Name)"
        }
        else { "Unknown" }
        $header = "-- Row-Level Security Policy: $policyName`r`n-- NOTE: Ensure predicate functions are created before applying this policy`r`n`r`n"
        [System.IO.File]::WriteAllText($workItem.OutputPath, $header, (New-Object System.Text.UTF8Encoding $false))
        $scripter.Options.AppendToFile = $true
      }

      # Script the objects
      $scripter.EnumScript($smoObjects.ToArray()) | Out-Null

      # Add trailing newline for SecurityPolicy to match sequential format
      if ($workItem.SpecialHandler -eq 'SecurityPolicy') {
        [System.IO.File]::AppendAllText($workItem.OutputPath, "`r`n", (New-Object System.Text.UTF8Encoding $false))
      }

      $result.Success = $true
    }
    catch {
      $result.Error = $_.Exception.Message
    }

    # Record result
    $ResultsBag.Add($result)

    # Increment progress (atomic)
    [System.Threading.Interlocked]::Increment($ProgressCounter) | Out-Null
  }
  #endregion

  #region Cleanup
  try {
    if ($serverConn -and $serverConn.IsOpen) {
      $serverConn.Disconnect()
    }
  }
  catch {
    # Ignore cleanup errors
  }
  #endregion
}





function Initialize-ParallelRunspacePool {
  <#
  .SYNOPSIS
      Creates and opens a runspace pool for parallel workers.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [int]$MaxWorkers
  )

  $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

  # Import SqlServer module in each runspace
  $sessionState.ImportPSModule('SqlServer')

  $pool = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspacePool(
    1,           # Min runspaces
    $MaxWorkers, # Max runspaces
    $sessionState,
    $Host
  )

  $pool.Open()

  return $pool
}

function Start-ParallelWorkers {
  <#
  .SYNOPSIS
      Starts parallel workers in the runspace pool.
  .OUTPUTS
      Array of worker objects with PowerShell and Handle properties.
  #>
  [CmdletBinding()]
  [OutputType([System.Collections.Generic.List[hashtable]])]
  param(
    [Parameter(Mandatory)]
    [System.Management.Automation.Runspaces.RunspacePool]$RunspacePool,

    [Parameter(Mandatory)]
    [int]$WorkerCount,

    [Parameter(Mandatory)]
    [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$WorkQueue,

    [Parameter(Mandatory)]
    [ref]$ProgressCounter,

    [Parameter(Mandatory)]
    [System.Collections.Concurrent.ConcurrentBag[hashtable]]$ResultsBag,

    [Parameter(Mandatory)]
    [hashtable]$ConnectionInfo,

    [Parameter(Mandatory)]
    [string]$TargetVersion
  )

  $workers = [System.Collections.Generic.List[hashtable]]::new()

  for ($i = 0; $i -lt $WorkerCount; $i++) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $RunspacePool

    $ps.AddScript($script:ParallelWorkerScriptBlock).AddParameters(@{
        WorkQueue       = $WorkQueue
        ProgressCounter = $ProgressCounter
        ResultsBag      = $ResultsBag
        ConnectionInfo  = $ConnectionInfo
        TargetVersion   = $TargetVersion
      }) | Out-Null

    $handle = $ps.BeginInvoke()

    $workers.Add(@{
        PowerShell = $ps
        Handle     = $handle
        Index      = $i
      })
  }

  # Use Write-Output with -NoEnumerate to prevent PowerShell from unwrapping single-item collections
  Write-Output -NoEnumerate $workers
}

function Wait-ParallelWorkers {
  <#
  .SYNOPSIS
      Waits for all parallel workers to complete, showing progress.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [System.Collections.Generic.List[hashtable]]$Workers,

    [Parameter(Mandatory)]
    [ref]$ProgressCounter,

    [Parameter(Mandatory)]
    [int]$TotalItems,

    [Parameter()]
    [int]$ProgressInterval = 50
  )

  $startTime = [DateTime]::Now
  $lastReported = 0

  # Poll until all workers complete
  while ($true) {
    $allComplete = $true
    foreach ($worker in $Workers) {
      if (-not $worker.Handle.IsCompleted) {
        $allComplete = $false
        break
      }
    }

    $current = $ProgressCounter.Value

    # Report progress at intervals
    if (($current - $lastReported) -ge $ProgressInterval -or $allComplete) {
      $pct = if ($TotalItems -gt 0) { [math]::Floor(($current / $TotalItems) * 100) } else { 0 }
      $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
      $rate = if ($elapsed -gt 0) { [math]::Round($current / $elapsed, 1) } else { 0 }

      Write-Host ("[Parallel] Processed {0}/{1} items ({2}%) - {3}/sec" -f $current, $TotalItems, $pct, $rate) -ForegroundColor Cyan
      $lastReported = $current
    }

    if ($allComplete) {
      break
    }

    Start-Sleep -Milliseconds 500
  }

  # End all workers and collect any errors
  foreach ($worker in $Workers) {
    try {
      $worker.PowerShell.EndInvoke($worker.Handle)
    }
    catch {
      Write-Warning "Worker $($worker.Index) ended with error: $_"
    }
    finally {
      $worker.PowerShell.Dispose()
    }
  }

  $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
  Write-Host ("[Parallel] All workers finished in {0:F1} seconds" -f $elapsed) -ForegroundColor Green
}



# === From parallel-work-items-part1.ps1 ===

# Parallel Export - Work Queue Builder Helper Functions
# These functions create work items for each object type
# Add to the "Parallel Export Functions" region in Export-SqlServerSchema.ps1

# NOTE: Add these functions AFTER Get-SmoObjectByIdentifier and BEFORE Export-DatabaseObjects



function Build-WorkItems-Schemas {
  <#
  .SYNOPSIS
  Builds work items for database schema export.
  .DESCRIPTION
  Creates export work items for user-defined schemas (excludes system schemas).
  Output: 03_Schemas folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Schemas') { return @() }

  $schemas = @($Database.Schemas | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  if ($schemas.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Schemas'
  $baseDir = Join-Path $OutputDir '03_Schemas'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($schema in $schemas) {
        $fileName = "$(Get-SafeFileName $($schema.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Schema' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $schema.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $fileName = "001_Schemas.sql"
      $objects = @($schemas | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Schema' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir $fileName) `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Sequences {
  <#
  .SYNOPSIS
  Builds work items for sequence object export.
  .DESCRIPTION
  Creates export work items for SQL Server sequences (auto-incrementing values).
  Supports single/schema/all grouping modes. Output: 04_Sequences folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Sequences') { return @() }

  $allSequences = @($Database.Sequences | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (Sequences have modify_date)
  $sequences = @(Get-DeltaFilteredCollection -Collection $allSequences -ObjectType 'Sequence')
  if ($sequences.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Sequences'
  $baseDir = Join-Path $OutputDir '04_Sequences'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($seq in $sequences) {
        $safeSchema = Get-SafeFileName $seq.Schema
        $safeName = Get-SafeFileName $seq.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Sequence' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $seq.Schema; Name = $seq.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $sequences | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Sequences.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Sequence' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($sequences | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Sequence' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Sequences.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-PartitionFunctions {
  <#
  .SYNOPSIS
  Builds work items for partition function export.
  .DESCRIPTION
  Creates export work items for partition functions that define data distribution boundaries.
  Database-level objects (no schema). Output: 05_PartitionFunctions folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'PartitionFunctions') { return @() }

  $partFuncs = @($Database.PartitionFunctions | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  if ($partFuncs.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'PartitionFunctions'
  $baseDir = Join-Path $OutputDir '05_PartitionFunctions'
  $scriptOpts = @{}

  # No schema property, so schema and all modes produce one file
  switch ($groupBy) {
    'single' {
      foreach ($pf in $partFuncs) {
        $fileName = "PartitionFunction.$(Get-SafeFileName $($pf.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'PartitionFunction' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $pf.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($partFuncs | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'PartitionFunction' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_AllPartitionFunctions.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-PartitionSchemes {
  <#
  .SYNOPSIS
  Builds work items for partition scheme export.
  .DESCRIPTION
  Creates export work items for partition schemes that map partition function boundaries to filegroups.
  Must be exported after partition functions. Output: 06_PartitionSchemes folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'PartitionSchemes') { return @() }

  $partSchemes = @($Database.PartitionSchemes | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  if ($partSchemes.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'PartitionSchemes'
  $baseDir = Join-Path $OutputDir '06_PartitionSchemes'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($ps in $partSchemes) {
        $fileName = "PartitionScheme.$(Get-SafeFileName $($ps.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'PartitionScheme' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $ps.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($partSchemes | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'PartitionScheme' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_AllPartitionSchemes.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-UserDefinedTypes {
  <#
  .SYNOPSIS
  Builds work items for user-defined type export.
  .DESCRIPTION
  Creates export work items for UDTs including alias types, CLR types, and table types.
  Must be exported before tables that use these types. Output: 07_Types folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'UserDefinedTypes') { return @() }

  # Collect all type variations
  $allTypes = @()
  try { $allTypes += @($Database.UserDefinedDataTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) }) } catch { Write-Verbose "Could not access UserDefinedDataTypes: $_" }
  try { $allTypes += @($Database.UserDefinedTableTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) }) } catch { Write-Verbose "Could not access UserDefinedTableTypes: $_" }
  try { $allTypes += @($Database.UserDefinedTypes | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) }) } catch { Write-Verbose "Could not access UserDefinedTypes (CLR types): $_" }

  if ($allTypes.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'UserDefinedTypes'
  $baseDir = Join-Path $OutputDir '07_Types'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($type in $allTypes) {
        $safeSchema = Get-SafeFileName $type.Schema
        $safeName = Get-SafeFileName $type.Name
        $fileName = "$safeSchema.$safeName.sql"
        # Determine specific type for worker lookup
        $objectType = if ($type.GetType().Name -eq 'UserDefinedDataType') { 'UserDefinedDataType' }
        elseif ($type.GetType().Name -eq 'UserDefinedTableType') { 'UserDefinedTableType' }
        else { 'UserDefinedType' }

        $workItems += New-ExportWorkItem `
          -ObjectType $objectType `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $type.Schema; Name = $type.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $allTypes | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Types.sql" -f $schemaNum, $safeSchema
        # Mix of type variations - worker will handle lookup
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'UserDefinedType' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($allTypes | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'UserDefinedType' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_AllTypes.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-XmlSchemaCollections {
  <#
  .SYNOPSIS
  Builds work items for XML schema collection export.
  .DESCRIPTION
  Creates export work items for XML schema collections used to validate XML columns.
  Must be exported before tables with typed XML columns. Output: 08_XmlSchemaCollections folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'XmlSchemaCollections') { return @() }

  $xmlSchemas = @($Database.XmlSchemaCollections | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  if ($xmlSchemas.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'XmlSchemaCollections'
  $baseDir = Join-Path $OutputDir '08_XmlSchemaCollections'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($xml in $xmlSchemas) {
        $safeSchema = Get-SafeFileName $xml.Schema
        $safeName = Get-SafeFileName $xml.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'XmlSchemaCollection' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $xml.Schema; Name = $xml.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $xmlSchemas | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_XmlSchemas.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'XmlSchemaCollection' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($xmlSchemas | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'XmlSchemaCollection' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_XmlSchemas.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Tables {
  <#
  .SYNOPSIS
  Builds work items for table export (structure with primary keys only).
  .DESCRIPTION
  Creates export work items for table DDL with primary keys but NOT foreign keys or indexes.
  FKs and indexes are exported separately to handle circular dependencies.
  Output: 09_Tables_PrimaryKey folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Tables') { return @() }

  $allTables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (Tables have modify_date)
  $tables = @(Get-DeltaFilteredCollection -Collection $allTables -ObjectType 'Table')
  if ($tables.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Tables'
  $baseDir = Join-Path $OutputDir '09_Tables_PrimaryKey'

  # Tables export with PKs but not FKs or indexes
  $scriptOpts = @{
    DriPrimaryKey       = $true
    DriForeignKeys      = $false
    DriUniqueKeys       = $true
    DriChecks           = $true
    DriDefaults         = $true
    Indexes             = $false
    ClusteredIndexes    = $false
    NonClusteredIndexes = $false
    XmlIndexes          = $false
    FullTextIndexes     = $false
    Triggers            = $false
  }

  switch ($groupBy) {
    'single' {
      foreach ($table in $tables) {
        $fileName = "$(Get-SafeFileName $($table.Schema)).$(Get-SafeFileName $($table.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Table' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $table.Schema; Name = $table.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $tables | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $fileName = "{0:D3}_{1}.sql" -f $schemaNum, (Get-SafeFileName $group.Name)
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Table' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($tables | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Table' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_AllTables.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

# Continue in next comment due to length...

# === From parallel-work-items-part2.ps1 ===

# Parallel Export - Work Queue Builders Part 2
# Continuation of helper functions

function Build-WorkItems-ForeignKeys {
  <#
  .SYNOPSIS
  Builds work items for foreign key constraint export.
  .DESCRIPTION
  Creates export work items for FK constraints as ALTER TABLE ADD CONSTRAINT statements.
  Exported separately from tables to avoid circular reference issues during import.
  Output: 10_Tables_ForeignKeys folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'ForeignKeys') { return @() }

  # Collect FKs from all tables
  $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  $fkList = @()
  foreach ($table in $tables) {
    if ($table.ForeignKeys.Count -gt 0) {
      foreach ($fk in $table.ForeignKeys) {
        $fkList += @{
          TableSchema = $table.Schema
          TableName   = $table.Name
          FKName      = $fk.Name
        }
      }
    }
  }

  if ($fkList.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'ForeignKeys'
  $baseDir = Join-Path $OutputDir '10_Tables_ForeignKeys'

  # For FKs, we script tables with FK-only options
  $scriptOpts = @{
    DriPrimaryKey                      = $false
    DriForeignKeys                     = $true
    DriUniqueKeys                      = $false
    DriChecks                          = $false
    DriDefaults                        = $false
    Indexes                            = $false
    SchemaQualifyForeignKeysReferences = $true
  }

  switch ($groupBy) {
    'single' {
      # One file per foreign key (matches sequential export naming: Schema.Table.FKName.sql)
      foreach ($fk in $fkList) {
        $fileName = "$(Get-SafeFileName $($fk.TableSchema)).$(Get-SafeFileName $($fk.TableName)).$(Get-SafeFileName $($fk.FKName)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableForeignKeys' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $fk.TableSchema; Name = $fk.TableName; FKName = $fk.FKName }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'ForeignKeys'
      }
    }
    'schema' {
      $bySchema = $fkList | Group-Object { $_.TableSchema }
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_ForeignKeys.sql" -f $schemaNum, $safeSchema
        $tableNames = $group.Group | Select-Object -Property TableSchema, TableName -Unique
        $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableForeignKeys' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'ForeignKeys'
        $schemaNum++
      }
    }
    'all' {
      $tableNames = $fkList | Select-Object -Property TableSchema, TableName -Unique
      $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'TableForeignKeys' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_ForeignKeys.sql') `
        -ScriptingOptions $scriptOpts `
        -SpecialHandler 'ForeignKeys'
    }
  }

  return $workItems
}

function Build-WorkItems-Indexes {
  <#
  .SYNOPSIS
  Builds work items for non-clustered index export.
  .DESCRIPTION
  Creates export work items for individual indexes (excludes primary key indexes).
  Each index gets its own work item with TableSchema, TableName, and IndexName identifiers.
  Output: 11_Indexes folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Indexes') { return @() }

  # Collect indexes from tables (same logic as sequential export)
  $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  $indexList = @()
  foreach ($table in $tables) {
    if ($table.Indexes.Count -gt 0) {
      foreach ($idx in $table.Indexes) {
        # Skip system indexes, primary key indexes, and unique key indexes (same as sequential)
        if (-not $idx.IsSystemObject -and
          -not ($idx.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriPrimaryKey) -and
          -not ($idx.IndexKeyType -eq [Microsoft.SqlServer.Management.Smo.IndexKeyType]::DriUniqueKey)) {
          $indexList += @{
            TableSchema = $table.Schema
            TableName   = $table.Name
            IndexName   = $idx.Name
          }
        }
      }
    }
  }

  if ($indexList.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Indexes'
  $baseDir = Join-Path $OutputDir '11_Indexes'

  # Script tables with index-only options
  $scriptOpts = @{
    DriAll              = $false
    Indexes             = $true
    ClusteredIndexes    = $false
    NonClusteredIndexes = $true
    XmlIndexes          = $true
    FullTextIndexes     = $false
  }

  switch ($groupBy) {
    'single' {
      # One file per index (matches sequential export naming: Schema.Table.IndexName.sql)
      foreach ($idx in $indexList) {
        $fileName = "$(Get-SafeFileName $($idx.TableSchema)).$(Get-SafeFileName $($idx.TableName)).$(Get-SafeFileName $($idx.IndexName)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Index' `
          -GroupingMode 'single' `
          -Objects @(@{ TableSchema = $idx.TableSchema; TableName = $idx.TableName; IndexName = $idx.IndexName }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'Indexes'
      }
    }
    'schema' {
      $bySchema = $indexList | Group-Object { $_.TableSchema }
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Indexes.sql" -f $schemaNum, $safeSchema
        # Pass individual index identifiers
        $indexObjects = @($group.Group | ForEach-Object { @{ TableSchema = $_.TableSchema; TableName = $_.TableName; IndexName = $_.IndexName } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Index' `
          -GroupingMode 'schema' `
          -Objects $indexObjects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'Indexes'
        $schemaNum++
      }
    }
    'all' {
      # Pass all individual index identifiers
      $indexObjects = @($indexList | ForEach-Object { @{ TableSchema = $_.TableSchema; TableName = $_.TableName; IndexName = $_.IndexName } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Index' `
        -GroupingMode 'all' `
        -Objects $indexObjects `
        -OutputPath (Join-Path $baseDir '001_Indexes.sql') `
        -ScriptingOptions $scriptOpts `
        -SpecialHandler 'Indexes'
    }
  }

  return $workItems
}

function Build-WorkItems-Defaults {
  <#
  .SYNOPSIS
  Builds work items for legacy default object export.
  .DESCRIPTION
  Creates export work items for standalone DEFAULT objects (deprecated, use DEFAULT constraints).
  Included for backward compatibility with older databases. Output: 12_Defaults folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Defaults') { return @() }

  $defaults = @($Database.Defaults | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  if ($defaults.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Defaults'
  $baseDir = Join-Path $OutputDir '12_Defaults'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($def in $defaults) {
        $safeSchema = Get-SafeFileName $def.Schema
        $safeName = Get-SafeFileName $def.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Default' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $def.Schema; Name = $def.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $defaults | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Defaults.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Default' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($defaults | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Default' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Defaults.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Rules {
  <#
  .SYNOPSIS
  Builds work items for legacy rule object export.
  .DESCRIPTION
  Creates export work items for standalone RULE objects (deprecated, use CHECK constraints).
  Included for backward compatibility with older databases. Output: 13_Rules folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Rules') { return @() }

  $rules = @($Database.Rules | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  if ($rules.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Rules'
  $baseDir = Join-Path $OutputDir '13_Rules'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($rule in $rules) {
        $safeSchema = Get-SafeFileName $rule.Schema
        $safeName = Get-SafeFileName $rule.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Rule' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $rule.Schema; Name = $rule.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $rules | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Rules.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Rule' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($rules | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Rule' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Rules.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Assemblies {
  <#
  .SYNOPSIS
  Builds work items for CLR assembly export.
  .DESCRIPTION
  Creates export work items for .NET assemblies registered in the database for CLR integration.
  Must be exported before CLR functions, procedures, or types that depend on them.
  Output: 14_Programmability folder (subfolder).
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Assemblies') { return @() }

  $assemblies = @($Database.Assemblies | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  if ($assemblies.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Assemblies'
  $baseDir = Join-Path $OutputDir '14_Programmability'
  $scriptOpts = @{}

  # Assemblies have no schema property
  switch ($groupBy) {
    'single' {
      foreach ($asm in $assemblies) {
        $fileName = "Assembly.$(Get-SafeFileName $($asm.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'SqlAssembly' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $asm.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($assemblies | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'SqlAssembly' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Assemblies.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

# Add remaining programmability objects: Functions, Aggregates, StoredProcedures, Triggers, Views, Synonyms
# Then: FullText, External Data, SearchPropertyLists, PlanGuides, Security, SecurityPolicies

# I'll create part 3 for the remaining functions...

# === From parallel-work-items-part3.ps1 ===

# Parallel Export - Work Queue Builders Part 3
# Remaining helper functions for all object types

function Build-WorkItems-Functions {
  <#
  .SYNOPSIS
  Builds work items for user-defined function export.
  .DESCRIPTION
  Creates export work items for scalar, table-valued, and CLR functions.
  May have cross-dependencies with views and procedures (handled by import retry logic).
  Output: 14_Programmability/Functions subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Functions') { return @() }

  $allFunctions = @($Database.UserDefinedFunctions | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (UserDefinedFunctions have modify_date)
  $functions = @(Get-DeltaFilteredCollection -Collection $allFunctions -ObjectType 'UserDefinedFunction')
  if ($functions.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Functions'
  $baseDir = Join-Path $OutputDir '14_Programmability' '02_Functions'
  # Match sequential mode scripting options
  $scriptOpts = @{
    Indexes  = $false
    Triggers = $false
  }

  switch ($groupBy) {
    'single' {
      foreach ($func in $functions) {
        $safeSchema = Get-SafeFileName $func.Schema
        $safeName = Get-SafeFileName $func.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'UserDefinedFunction' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $func.Schema; Name = $func.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $functions | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Functions.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'UserDefinedFunction' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($functions | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'UserDefinedFunction' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Functions.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-UserDefinedAggregates {
  <#
  .SYNOPSIS
  Builds work items for CLR user-defined aggregate export.
  .DESCRIPTION
  Creates export work items for custom aggregate functions implemented via CLR.
  Requires corresponding CLR assembly to be loaded first.
  Output: 14_Programmability/UserDefinedAggregates subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'UserDefinedAggregates') { return @() }

  try {
    $aggregates = @($Database.UserDefinedAggregates | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access UserDefinedAggregates (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($aggregates.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'UserDefinedAggregates'
  $baseDir = Join-Path $OutputDir '14_Programmability' '02_Functions'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($agg in $aggregates) {
        $safeSchema = Get-SafeFileName $agg.Schema
        $safeName = Get-SafeFileName $agg.Name
        # Use .aggregate.sql suffix to match sequential export
        $fileName = "$safeSchema.$safeName.aggregate.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'UserDefinedAggregate' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $agg.Schema; Name = $agg.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $aggregates | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        # Use .aggregates.sql suffix to match sequential export
        $fileName = "{0:D3}_{1}.aggregates.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'UserDefinedAggregate' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($aggregates | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'UserDefinedAggregate' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Aggregates.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-StoredProcedures {
  <#
  .SYNOPSIS
  Builds work items for stored procedure export.
  .DESCRIPTION
  Creates export work items for T-SQL, CLR, and extended stored procedures.
  May have cross-dependencies with functions and views (handled by import retry logic).
  Output: 14_Programmability/StoredProcedures subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'StoredProcedures') { return @() }

  $allProcs = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (StoredProcedures have modify_date)
  $procs = @(Get-DeltaFilteredCollection -Collection $allProcs -ObjectType 'StoredProcedure')

  # Also get extended stored procedures (don't have modify_date, always export)
  $extendedProcs = @()
  try {
    $extendedProcs = @($Database.ExtendedStoredProcedures | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access ExtendedStoredProcedures: $_"
  }

  if ($procs.Count -eq 0 -and $extendedProcs.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'StoredProcedures'
  $baseDir = Join-Path $OutputDir '14_Programmability' '03_StoredProcedures'
  # Match sequential mode scripting options
  $scriptOpts = @{
    Indexes  = $false
    Triggers = $false
  }

  switch ($groupBy) {
    'single' {
      # Regular stored procedures
      foreach ($proc in $procs) {
        $safeSchema = Get-SafeFileName $proc.Schema
        $safeName = Get-SafeFileName $proc.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'StoredProcedure' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $proc.Schema; Name = $proc.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
      # Extended stored procedures (with .extended.sql suffix to match sequential)
      foreach ($extProc in $extendedProcs) {
        $safeSchema = Get-SafeFileName $extProc.Schema
        $safeName = Get-SafeFileName $extProc.Name
        $fileName = "$safeSchema.$safeName.extended.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'ExtendedStoredProcedure' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $extProc.Schema; Name = $extProc.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      # Combine regular and extended procs for schema grouping
      $allProcsForGrouping = @($procs) + @($extendedProcs)
      $bySchema = $allProcsForGrouping | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_StoredProcedures.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'StoredProcedure' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      # Combine regular and extended procs for all grouping
      $allProcsForGrouping = @($procs) + @($extendedProcs)
      $objects = @($allProcsForGrouping | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'StoredProcedure' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_StoredProcedures.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-DatabaseTriggers {
  <#
  .SYNOPSIS
  Builds work items for database-level DDL trigger export.
  .DESCRIPTION
  Creates export work items for DDL triggers that respond to database events (CREATE, ALTER, DROP).
  Database-scoped, not tied to specific tables. Output: 14_Programmability/DatabaseTriggers subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'DatabaseTriggers') { return @() }

  $triggers = @($Database.Triggers | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  if ($triggers.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'DatabaseTriggers'
  $baseDir = Join-Path $OutputDir '14_Programmability'
  $scriptOpts = @{}

  # Database triggers have no schema property
  switch ($groupBy) {
    'single' {
      foreach ($trigger in $triggers) {
        $fileName = "Trigger.$(Get-SafeFileName $($trigger.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'DatabaseTrigger' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $trigger.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($triggers | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'DatabaseTrigger' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_DatabaseTriggers.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-TableTriggers {
  <#
  .SYNOPSIS
  Builds work items for table-level DML trigger export.
  .DESCRIPTION
  Creates export work items for DML triggers (INSERT, UPDATE, DELETE) attached to tables.
  Iterates all tables and collects their triggers with parent table context.
  Output: 14_Programmability/TableTriggers subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'TableTriggers') { return @() }

  # Collect triggers from tables
  $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  $triggerList = @()
  foreach ($table in $tables) {
    if ($table.Triggers.Count -gt 0) {
      foreach ($trigger in $table.Triggers) {
        # Apply delta filtering (Triggers have modify_date)
        if (Test-ShouldExportInDelta -ObjectType 'Trigger' -Schema $table.Schema -Name $trigger.Name) {
          $triggerList += @{
            TableSchema = $table.Schema
            TableName   = $table.Name
            TriggerName = $trigger.Name
          }
        }
      }
    }
  }

  if ($triggerList.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'TableTriggers'
  $baseDir = Join-Path $OutputDir '14_Programmability'
  # Match sequential mode scripting options for table triggers
  $scriptOpts = @{
    ClusteredIndexes = $false
    Default          = $false
    DriAll           = $false
    Indexes          = $false
    Triggers         = $true
    ScriptData       = $false
  }

  switch ($groupBy) {
    'single' {
      # One file per trigger (matches sequential export naming: Schema.Table.TriggerName.sql)
      foreach ($trigger in $triggerList) {
        $fileName = "$(Get-SafeFileName $($trigger.TableSchema)).$(Get-SafeFileName $($trigger.TableName)).$(Get-SafeFileName $($trigger.TriggerName)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableTriggers' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $trigger.TableSchema; Name = $trigger.TableName; TriggerName = $trigger.TriggerName }) `
          -OutputPath (Join-Path $baseDir '04_Triggers' $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'TableTriggers'
      }
    }
    'schema' {
      $bySchema = $triggerList | Group-Object { $_.TableSchema }
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_TableTriggers.sql" -f $schemaNum, $safeSchema
        $tableNames = $group.Group | Select-Object -Property TableSchema, TableName -Unique
        $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableTriggers' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'TableTriggers'
        $schemaNum++
      }
    }
    'all' {
      $tableNames = $triggerList | Select-Object -Property TableSchema, TableName -Unique
      $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'TableTriggers' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_TableTriggers.sql') `
        -ScriptingOptions $scriptOpts `
        -SpecialHandler 'TableTriggers'
    }
  }

  return $workItems
}

function Build-WorkItems-Views {
  <#
  .SYNOPSIS
  Builds work items for view export.
  .DESCRIPTION
  Creates export work items for database views (excludes system views).
  May have cross-dependencies with functions and other views (handled by import retry logic).
  Output: 14_Programmability/Views subfolder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Views') { return @() }

  $allViews = @($Database.Views | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (Views have modify_date)
  $views = @(Get-DeltaFilteredCollection -Collection $allViews -ObjectType 'View')
  if ($views.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Views'
  $baseDir = Join-Path $OutputDir '14_Programmability' '05_Views'
  $scriptOpts = @{ DriAll = $false }

  switch ($groupBy) {
    'single' {
      foreach ($view in $views) {
        $safeSchema = Get-SafeFileName $view.Schema
        $safeName = Get-SafeFileName $view.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'View' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $view.Schema; Name = $view.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $views | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Views.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'View' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($views | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'View' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Views.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Synonyms {
  <#
  .SYNOPSIS
  Builds work items for synonym export.
  .DESCRIPTION
  Creates export work items for database synonyms (aliases for other database objects).
  May reference objects in other databases or linked servers. Output: 15_Synonyms folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'Synonyms') { return @() }

  $allSynonyms = @($Database.Synonyms | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  # Apply delta filtering (Synonyms have modify_date)
  $synonyms = @(Get-DeltaFilteredCollection -Collection $allSynonyms -ObjectType 'Synonym')
  if ($synonyms.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Synonyms'
  $baseDir = Join-Path $OutputDir '15_Synonyms'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($syn in $synonyms) {
        $safeSchema = Get-SafeFileName $syn.Schema
        $safeName = Get-SafeFileName $syn.Name
        $fileName = "$safeSchema.$safeName.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'Synonym' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $syn.Schema; Name = $syn.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $synonyms | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Synonyms.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Synonym' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($synonyms | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'Synonym' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Synonyms.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-FullTextCatalogs {
  <#
  .SYNOPSIS
  Builds work items for full-text catalog export.
  .DESCRIPTION
  Creates export work items for full-text search catalogs (containers for full-text indexes).
  Database-level objects. Output: 16_FullTextSearch folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'FullTextCatalogs') { return @() }

  try {
    $ftCatalogs = @($Database.FullTextCatalogs | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access FullTextCatalogs (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($ftCatalogs.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'FullTextCatalogs'
  $baseDir = Join-Path $OutputDir '16_FullTextSearch'
  $scriptOpts = @{}

  # No schema property
  switch ($groupBy) {
    'single' {
      foreach ($ftCat in $ftCatalogs) {
        $fileName = "FullTextCatalog.$(Get-SafeFileName $($ftCat.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'FullTextCatalog' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $ftCat.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($ftCatalogs | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'FullTextCatalog' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_FullTextCatalogs.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-FullTextStopLists {
  <#
  .SYNOPSIS
  Builds work items for full-text stoplist export.
  .DESCRIPTION
  Creates export work items for full-text stoplists (noise word exclusion lists).
  Used by full-text indexes to filter common words. Output: 16_FullTextSearch folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'FullTextStopLists') { return @() }

  try {
    $ftStopLists = @($Database.FullTextStopLists | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access FullTextStopLists (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($ftStopLists.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'FullTextStopLists'
  $baseDir = Join-Path $OutputDir '16_FullTextSearch'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($stopList in $ftStopLists) {
        $fileName = "FullTextStopList.$(Get-SafeFileName $($stopList.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'FullTextStopList' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $stopList.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($ftStopLists | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'FullTextStopList' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_FullTextStopLists.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-ExternalDataSources {
  <#
  .SYNOPSIS
  Builds work items for external data source export.
  .DESCRIPTION
  Creates export work items for PolyBase external data sources (Hadoop, Azure Blob, etc.).
  Used with external tables for data virtualization. Output: 17_ExternalData folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'ExternalDataSources') { return @() }

  try {
    $extDS = @($Database.ExternalDataSources | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access ExternalDataSources (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($extDS.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'ExternalDataSources'
  $baseDir = Join-Path $OutputDir '17_ExternalData'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($ds in $extDS) {
        $fileName = "ExternalDataSource.$(Get-SafeFileName $($ds.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'ExternalDataSource' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $ds.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($extDS | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'ExternalDataSource' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_ExternalDataSources.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-ExternalFileFormats {
  <#
  .SYNOPSIS
  Builds work items for external file format export.
  .DESCRIPTION
  Creates export work items for PolyBase external file formats (CSV, Parquet, ORC, etc.).
  Defines structure of data in external data sources. Output: 17_ExternalData folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'ExternalFileFormats') { return @() }

  try {
    $extFF = @($Database.ExternalFileFormats | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access ExternalFileFormats (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($extFF.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'ExternalFileFormats'
  $baseDir = Join-Path $OutputDir '17_ExternalData'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($ff in $extFF) {
        $fileName = "ExternalFileFormat.$(Get-SafeFileName $($ff.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'ExternalFileFormat' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $ff.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($extFF | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'ExternalFileFormat' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_ExternalFileFormats.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-SearchPropertyLists {
  <#
  .SYNOPSIS
  Builds work items for search property list export.
  .DESCRIPTION
  Creates export work items for full-text search property lists (document property definitions).
  Used for property searching in full-text indexes. Output: 18_SearchPropertyLists folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'SearchPropertyLists') { return @() }

  try {
    $searchPropLists = @($Database.SearchPropertyLists | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access SearchPropertyLists (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($searchPropLists.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'SearchPropertyLists'
  $baseDir = Join-Path $OutputDir '18_SearchPropertyLists'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($spl in $searchPropLists) {
        $fileName = "SearchPropertyList.$(Get-SafeFileName $($spl.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'SearchPropertyList' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $spl.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($searchPropLists | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'SearchPropertyList' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_SearchPropertyLists.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-PlanGuides {
  <#
  .SYNOPSIS
  Builds work items for plan guide export.
  .DESCRIPTION
  Creates export work items for query plan guides (hints for query optimizer).
  Used to influence execution plans without modifying application code. Output: 19_PlanGuides folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'PlanGuides') { return @() }

  try {
    $planGuides = @($Database.PlanGuides | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access PlanGuides (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($planGuides.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'PlanGuides'
  $baseDir = Join-Path $OutputDir '19_PlanGuides'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($pg in $planGuides) {
        $fileName = "PlanGuide.$(Get-SafeFileName $($pg.Name)).sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'PlanGuide' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $pg.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    { $_ -in 'schema', 'all' } {
      $objects = @($planGuides | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'PlanGuide' `
        -GroupingMode $groupBy `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_PlanGuides.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-WorkItems-Security {
  <#
  .SYNOPSIS
  Builds work items for security object export.
  .DESCRIPTION
  Creates export work items for database security objects: Certificates, Asymmetric Keys,
  Symmetric Keys, Database Roles, Application Roles, and Database Users.
  All security objects grouped in 01_Security folder (exported first for dependency order).
  #>
  param($Database, $OutputDir)

  # Security objects are grouped together: Certificates, Keys, Roles, Users
  $workItems = @()
  $baseDir = Join-Path $OutputDir '01_Security'

  # Certificates
  if (-not (Test-ObjectTypeExcluded -ObjectType 'Certificates')) {
    try {
      $certs = @($Database.Certificates | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($certs.Count -gt 0) {
        $objects = @($certs | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'Certificate' `
          -GroupingMode 'all' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir '001_Certificates.sql') `
          -ScriptingOptions @{}
      }
    }
    catch { Write-Verbose "Could not access Certificates collection: $_" }
  }

  # Asymmetric Keys
  if (-not (Test-ObjectTypeExcluded -ObjectType 'AsymmetricKeys')) {
    try {
      $asymKeys = @($Database.AsymmetricKeys | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($asymKeys.Count -gt 0) {
        $objects = @($asymKeys | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'AsymmetricKey' `
          -GroupingMode 'all' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir '002_AsymmetricKeys.sql') `
          -ScriptingOptions @{}
      }
    }
    catch { Write-Verbose "Could not access AsymmetricKeys collection: $_" }
  }

  # Symmetric Keys
  if (-not (Test-ObjectTypeExcluded -ObjectType 'SymmetricKeys')) {
    try {
      $symKeys = @($Database.SymmetricKeys | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($symKeys.Count -gt 0) {
        $objects = @($symKeys | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'SymmetricKey' `
          -GroupingMode 'all' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir '003_SymmetricKeys.sql') `
          -ScriptingOptions @{}
      }
    }
    catch { Write-Verbose "Could not access SymmetricKeys collection: $_" }
  }

  # Database Roles - respect grouping mode (default: single to match sequential export)
  if (-not (Test-ObjectTypeExcluded -ObjectType 'DatabaseRoles')) {
    $groupBy = Get-ObjectGroupingMode -ObjectType 'DatabaseRoles'
    try {
      $dbRoles = @($Database.Roles | Where-Object { -not $_.IsFixedRole -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($dbRoles.Count -gt 0) {
        switch ($groupBy) {
          'single' {
            # One file per role: RoleName.role.sql (matches sequential export)
            foreach ($role in $dbRoles) {
              $safeName = Get-SafeFileName $role.Name
              $fileName = "$safeName.role.sql"
              $workItems += New-ExportWorkItem `
                -ObjectType 'DatabaseRole' `
                -GroupingMode 'single' `
                -Objects @(@{ Schema = $null; Name = $role.Name }) `
                -OutputPath (Join-Path $baseDir $fileName) `
                -ScriptingOptions @{}
            }
          }
          default {
            # 'schema' or 'all' - consolidated file
            $objects = @($dbRoles | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
            $workItems += New-ExportWorkItem `
              -ObjectType 'DatabaseRole' `
              -GroupingMode $groupBy `
              -Objects $objects `
              -OutputPath (Join-Path $baseDir '004_Roles.sql') `
              -ScriptingOptions @{}
          }
        }
      }
    }
    catch { Write-Verbose "Could not access Roles collection: $_" }

    # Application Roles
    try {
      $appRoles = @($Database.ApplicationRoles | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($appRoles.Count -gt 0) {
        switch ($groupBy) {
          'single' {
            foreach ($role in $appRoles) {
              $safeName = Get-SafeFileName $role.Name
              $fileName = "$safeName.approle.sql"
              $workItems += New-ExportWorkItem `
                -ObjectType 'ApplicationRole' `
                -GroupingMode 'single' `
                -Objects @(@{ Schema = $null; Name = $role.Name }) `
                -OutputPath (Join-Path $baseDir $fileName) `
                -ScriptingOptions @{}
            }
          }
          default {
            $objects = @($appRoles | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
            $workItems += New-ExportWorkItem `
              -ObjectType 'ApplicationRole' `
              -GroupingMode $groupBy `
              -Objects $objects `
              -OutputPath (Join-Path $baseDir '005_ApplicationRoles.sql') `
              -ScriptingOptions @{}
          }
        }
      }
    }
    catch { Write-Verbose "Could not access ApplicationRoles collection: $_" }
  }

  # Database Users - respect grouping mode (default: single to match sequential export)
  if (-not (Test-ObjectTypeExcluded -ObjectType 'DatabaseUsers')) {
    $groupBy = Get-ObjectGroupingMode -ObjectType 'DatabaseUsers'
    try {
      $users = @($Database.Users | Where-Object { -not $_.IsSystemObject -and $_.Name -ne 'dbo' -and -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
      if ($users.Count -gt 0) {
        switch ($groupBy) {
          'single' {
            # One file per user: UserName.user.sql (matches sequential export)
            foreach ($user in $users) {
              $safeName = Get-SafeFileName $user.Name
              $fileName = "$safeName.user.sql"
              $workItems += New-ExportWorkItem `
                -ObjectType 'User' `
                -GroupingMode 'single' `
                -Objects @(@{ Schema = $null; Name = $user.Name }) `
                -OutputPath (Join-Path $baseDir $fileName) `
                -ScriptingOptions @{}
            }
          }
          default {
            # 'schema' or 'all' - consolidated file
            $objects = @($users | ForEach-Object { @{ Schema = $null; Name = $_.Name } })
            $workItems += New-ExportWorkItem `
              -ObjectType 'User' `
              -GroupingMode $groupBy `
              -Objects $objects `
              -OutputPath (Join-Path $baseDir '006_Users.sql') `
              -ScriptingOptions @{}
          }
        }
      }
    }
    catch { Write-Verbose "Could not access Users collection: $_" }
  }

  # Database Audit Specifications (matches sequential export)
  try {
    $auditSpecs = @($Database.DatabaseAuditSpecifications | Where-Object { -not (Test-ObjectExcluded -Schema $null -Name $_.Name) })
    if ($auditSpecs.Count -gt 0) {
      # Audit specs are always exported individually to match sequential mode
      foreach ($spec in $auditSpecs) {
        $safeName = Get-SafeFileName $spec.Name
        $fileName = "$safeName.auditspec.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'DatabaseAuditSpecification' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $null; Name = $spec.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions @{}
      }
    }
  }
  catch { Write-Verbose "Could not access DatabaseAuditSpecifications collection: $_" }

  return $workItems
}

function Build-WorkItems-SecurityPolicies {
  <#
  .SYNOPSIS
  Builds work items for Row-Level Security (RLS) policy export.
  .DESCRIPTION
  Creates export work items for security policies with filter and block predicates.
  Exported AFTER programmability objects because policies reference predicate functions.
  Output: 20_SecurityPolicies folder.
  #>
  param($Database, $OutputDir)

  if (Test-ObjectTypeExcluded -ObjectType 'SecurityPolicies') { return @() }

  try {
    $secPolicies = @($Database.SecurityPolicies | Where-Object { -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })
  }
  catch {
    Write-Verbose "Could not access SecurityPolicies (may not be supported on this SQL Server version): $_"
    return @()
  }

  if ($secPolicies.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'SecurityPolicies'
  $baseDir = Join-Path $OutputDir '20_SecurityPolicies'
  $scriptOpts = @{}

  switch ($groupBy) {
    'single' {
      foreach ($policy in $secPolicies) {
        $safeSchema = Get-SafeFileName $policy.Schema
        $safeName = Get-SafeFileName $policy.Name
        $fileName = "$safeSchema.$safeName.securitypolicy.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'SecurityPolicy' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $policy.Schema; Name = $policy.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'SecurityPolicy'
      }
    }
    'schema' {
      $bySchema = $secPolicies | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_SecurityPolicies.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'SecurityPolicy' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts `
          -SpecialHandler 'SecurityPolicy'
        $schemaNum++
      }
    }
    'all' {
      $objects = @($secPolicies | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'SecurityPolicy' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_SecurityPolicies.sql') `
        -ScriptingOptions $scriptOpts `
        -SpecialHandler 'SecurityPolicy'
    }
  }

  return $workItems
}



# === From parallel-orchestrators.ps1 ===

# Parallel Export - Orchestrator Functions

function Build-WorkItems-Data {
  <#
  .SYNOPSIS
  Builds work items for table data export if -IncludeData is enabled.

  .DESCRIPTION
  Pre-fetches row counts for all tables in a single query to avoid N round-trips.
  Only includes tables that have data (skips empty tables for efficiency).
  #>
  param($Database, $OutputDir)

  if (-not $script:IncludeData) { return @() }
  if (Test-ObjectTypeExcluded -ObjectType 'Data') { return @() }

  $tables = @($Database.Tables | Where-Object {
      -not $_.IsSystemObject -and
      -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name)
    })

  if ($tables.Count -eq 0) { return @() }

  # OPTIMIZATION: Pre-fetch row counts in a single query (same as Export-TableData)
  # This reduces N database round-trips to just 1
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
HAVING SUM(p.rows) > 0
"@
  $rowCountData = $Database.ExecuteWithResults($rowCountQuery)
  $tablesWithData = @{}
  foreach ($row in $rowCountData.Tables[0].Rows) {
    $key = "$($row.SchemaName).$($row.TableName)"
    $tablesWithData[$key] = [long]$row.TableRowCount
  }

  # Filter to only tables with data
  $tables = @($tables | Where-Object {
      $key = "$($_.Schema).$($_.Name)"
      $tablesWithData.ContainsKey($key)
    })

  if ($tables.Count -eq 0) { return @() }

  $workItems = @()
  $groupBy = Get-ObjectGroupingMode -ObjectType 'Data'
  $baseDir = Join-Path $OutputDir '21_Data'
  $scriptOpts = @{ ScriptData = $true; NoCommandTerminator = $true }

  switch ($groupBy) {
    'single' {
      foreach ($table in $tables) {
        $safeSchema = Get-SafeFileName $table.Schema
        $safeName = Get-SafeFileName $table.Name
        $fileName = "$safeSchema.$safeName.data.sql"
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableData' `
          -GroupingMode 'single' `
          -Objects @(@{ Schema = $table.Schema; Name = $table.Name }) `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
      }
    }
    'schema' {
      $bySchema = $tables | Group-Object Schema
      $schemaNum = 1
      foreach ($group in $bySchema | Sort-Object Name) {
        $safeSchema = Get-SafeFileName $group.Name
        $fileName = "{0:D3}_{1}_Data.sql" -f $schemaNum, $safeSchema
        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
        $workItems += New-ExportWorkItem `
          -ObjectType 'TableData' `
          -GroupingMode 'schema' `
          -Objects $objects `
          -OutputPath (Join-Path $baseDir $fileName) `
          -ScriptingOptions $scriptOpts
        $schemaNum++
      }
    }
    'all' {
      $objects = @($tables | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
      $workItems += New-ExportWorkItem `
        -ObjectType 'TableData' `
        -GroupingMode 'all' `
        -Objects $objects `
        -OutputPath (Join-Path $baseDir '001_Data.sql') `
        -ScriptingOptions $scriptOpts
    }
  }

  return $workItems
}

function Build-ParallelWorkQueue {
  <#
  .SYNOPSIS
  Builds the complete work queue for parallel export by calling all helper functions.

  .DESCRIPTION
  Orchestrates all Build-WorkItems-* helper functions to create a comprehensive work queue.
  Returns an array of work items ready for parallel processing.

  .PARAMETER Database
  The SMO Database object to export from.

  .PARAMETER OutputDir
  The output directory where scripts will be exported.

  .OUTPUTS
  System.Collections.ArrayList
  Array of work item hashtables, each containing ObjectType, GroupingMode, Objects, OutputPath, etc.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [Microsoft.SqlServer.Management.Smo.Database]$Database,

    [Parameter(Mandatory)]
    [string]$OutputDir
  )

  Write-Host "  [INFO] Building parallel work queue..." -ForegroundColor Cyan

  $workQueue = [System.Collections.Generic.List[hashtable]]::new()

  # Call all helper functions in logical order (matches folder structure)
  $builders = @(
    { Build-WorkItems-Schemas $Database $OutputDir }
    { Build-WorkItems-Sequences $Database $OutputDir }
    { Build-WorkItems-PartitionFunctions $Database $OutputDir }
    { Build-WorkItems-PartitionSchemes $Database $OutputDir }
    { Build-WorkItems-UserDefinedTypes $Database $OutputDir }
    { Build-WorkItems-XmlSchemaCollections $Database $OutputDir }
    { Build-WorkItems-Tables $Database $OutputDir }
    { Build-WorkItems-ForeignKeys $Database $OutputDir }
    { Build-WorkItems-Indexes $Database $OutputDir }
    { Build-WorkItems-Defaults $Database $OutputDir }
    { Build-WorkItems-Rules $Database $OutputDir }
    { Build-WorkItems-Assemblies $Database $OutputDir }
    { Build-WorkItems-Functions $Database $OutputDir }
    { Build-WorkItems-UserDefinedAggregates $Database $OutputDir }
    { Build-WorkItems-StoredProcedures $Database $OutputDir }
    { Build-WorkItems-DatabaseTriggers $Database $OutputDir }
    { Build-WorkItems-TableTriggers $Database $OutputDir }
    { Build-WorkItems-Views $Database $OutputDir }
    { Build-WorkItems-Synonyms $Database $OutputDir }
    { Build-WorkItems-FullTextCatalogs $Database $OutputDir }
    { Build-WorkItems-FullTextStopLists $Database $OutputDir }
    { Build-WorkItems-ExternalDataSources $Database $OutputDir }
    { Build-WorkItems-ExternalFileFormats $Database $OutputDir }
    { Build-WorkItems-SearchPropertyLists $Database $OutputDir }
    { Build-WorkItems-PlanGuides $Database $OutputDir }
    { Build-WorkItems-Security $Database $OutputDir }
    { Build-WorkItems-SecurityPolicies $Database $OutputDir }
    { Build-WorkItems-Data $Database $OutputDir }
  )

  foreach ($builder in $builders) {
    try {
      $items = & $builder
      if ($items) {
        # Add each item individually to avoid type conversion issues
        foreach ($item in $items) {
          if ($item -is [hashtable]) {
            $workQueue.Add($item)
          }
        }
      }
    }
    catch {
      Write-Host "  [WARNING] Error in work queue builder: $_" -ForegroundColor Yellow
    }
  }

  Write-Host "  [SUCCESS] Built $($workQueue.Count) work items for parallel processing" -ForegroundColor Green
  return $workQueue
}

function Export-NonParallelizableObjects {
  <#
  .SYNOPSIS
      Exports objects that cannot be parallelized (FileGroups, DatabaseScopedConfigurations, Credentials).
  .DESCRIPTION
      These objects require StringBuilder-based generation for SQLCMD variable support
      or security reasons. This function is called by both sequential and parallel export
      modes to ensure identical output.
  .PARAMETER Database
      The SMO Database object to export from.
  .PARAMETER OutputDir
      The output directory where scripts will be exported.
  .PARAMETER Quiet
      If true, suppress progress messages (used when called from parallel mode).
  .OUTPUTS
      Hashtable with counts of exported objects.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    $Database,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [switch]$Quiet
  )

  $results = @{
    FileGroups                   = 0
    DatabaseScopedConfigurations = 0
    DatabaseScopedCredentials    = 0
  }

  # FileGroups (folder 00_FileGroups) - uses StringBuilder for SQLCMD variable support
  if (-not (Test-ObjectTypeExcluded -ObjectType 'FileGroups')) {
    try {
      $fileGroups = @($Database.FileGroups | Where-Object { $_.Name -ne 'PRIMARY' })
      if ($fileGroups.Count -gt 0) {
        $fgFilePath = Join-Path $OutputDir '00_FileGroups' '001_FileGroups.sql'
        $fgScript = New-Object System.Text.StringBuilder
        [void]$fgScript.AppendLine("-- FileGroups and Files")
        [void]$fgScript.AppendLine("-- WARNING: Physical file paths and sizes are environment-specific")
        [void]$fgScript.AppendLine("-- Review and update via config file before applying to target environment")
        [void]$fgScript.AppendLine("-- Uses SQLCMD variables: `$(FG_NAME_PATH_FILE), `$(FG_NAME_SIZE), `$(FG_NAME_GROWTH)")
        [void]$fgScript.AppendLine("")

        foreach ($fg in $fileGroups) {
          # Build metadata entry for this FileGroup
          $fgMetadata = [ordered]@{
            name       = $fg.Name
            type       = $fg.FileGroupType.ToString()
            isReadOnly = $fg.IsReadOnly
            files      = [System.Collections.ArrayList]::new()
          }

          [void]$fgScript.AppendLine("-- FileGroup: $($fg.Name)")
          [void]$fgScript.AppendLine("-- Type: $($fg.FileGroupType)")

          if ($fg.FileGroupType -eq 'RowsFileGroup') {
            [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILEGROUP [$($fg.Name)];")
          }
          else {
            [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILEGROUP [$($fg.Name)] CONTAINS FILESTREAM;")
          }
          [void]$fgScript.AppendLine("GO")

          if ($fg.IsReadOnly) {
            [void]$fgScript.AppendLine("ALTER DATABASE CURRENT MODIFY FILEGROUP [$($fg.Name)] READONLY;")
            [void]$fgScript.AppendLine("GO")
          }
          [void]$fgScript.AppendLine("")

          # Script files in the filegroup
          $fileIdx = 0
          foreach ($file in $fg.Files) {
            $fileIdx++
            $sqlcmdVarBase = $fg.Name
            $fileName = Split-Path $file.FileName -Leaf
            if (-not $fileName) { $fileName = "$($file.Name).ndf" }

            # Build variable names (consistent with path variables)
            $pathVar = if ($fileIdx -eq 1) { "${sqlcmdVarBase}_PATH_FILE" } else { "${sqlcmdVarBase}_PATH_FILE${fileIdx}" }
            $sizeVar = if ($fileIdx -eq 1) { "${sqlcmdVarBase}_SIZE" } else { "${sqlcmdVarBase}_SIZE${fileIdx}" }
            $growthVar = if ($fileIdx -eq 1) { "${sqlcmdVarBase}_GROWTH" } else { "${sqlcmdVarBase}_GROWTH${fileIdx}" }

            # Store original values in metadata
            $fileMetadata = [ordered]@{
              name               = $file.Name
              originalPath       = $file.FileName
              originalFileName   = $fileName
              originalSizeKB     = $file.Size
              originalGrowthKB   = if ($file.GrowthType -eq 'KB') { $file.Growth } else { $null }
              originalGrowthPct  = if ($file.GrowthType -ne 'KB') { $file.Growth } else { $null }
              originalGrowthType = $file.GrowthType.ToString()
              originalMaxSizeKB  = $file.MaxSize
              pathVariable       = $pathVar
              sizeVariable       = $sizeVar
              growthVariable     = $growthVar
            }
            [void]$fgMetadata.files.Add($fileMetadata)

            [void]$fgScript.AppendLine("-- File: $($file.Name)")
            [void]$fgScript.AppendLine("-- Original Path: $($file.FileName)")
            [void]$fgScript.AppendLine("-- Original Size: $($file.Size)KB, Growth: $($file.Growth)$(if ($file.GrowthType -eq 'KB') {'KB'} else {'%'}), MaxSize: $(if ($file.MaxSize -eq -1) {'UNLIMITED'} else {$file.MaxSize + 'KB'})")
            [void]$fgScript.AppendLine("-- NOTE: Uses SQLCMD variables for path, size, and growth")
            [void]$fgScript.AppendLine("-- Configure via fileGroupPathMapping and fileGroupFileSizeDefaults in config file")
            [void]$fgScript.AppendLine("ALTER DATABASE CURRENT ADD FILE (")
            [void]$fgScript.AppendLine("    NAME = N'$($file.Name)',")
            [void]$fgScript.AppendLine("    FILENAME = N'`$($pathVar)',")
            [void]$fgScript.AppendLine("    SIZE = `$($sizeVar)")
            [void]$fgScript.AppendLine("    , FILEGROWTH = `$($growthVar)")

            if ($file.MaxSize -gt 0) {
              [void]$fgScript.AppendLine("    , MAXSIZE = $($file.MaxSize)KB")
            }
            elseif ($file.MaxSize -eq -1) {
              [void]$fgScript.AppendLine("    , MAXSIZE = UNLIMITED")
            }

            [void]$fgScript.AppendLine(") TO FILEGROUP [$($fg.Name)];")
            [void]$fgScript.AppendLine("GO")
            [void]$fgScript.AppendLine("")
          }

          # Add FileGroup metadata to export metadata
          [void]$script:ExportMetadata.FileGroups.Add($fgMetadata)
        }

        # Ensure directory exists
        $fgDir = Split-Path $fgFilePath -Parent
        if (-not (Test-Path $fgDir)) {
          New-Item -ItemType Directory -Path $fgDir -Force | Out-Null
        }

        $fgScript.ToString() | Out-File -FilePath $fgFilePath -Encoding UTF8
        $results.FileGroups = $fileGroups.Count
        if (-not $Quiet) {
          Write-Host "  [SUCCESS] Exported $($fileGroups.Count) filegroup(s)" -ForegroundColor Green
        }
      }
    }
    catch {
      if (-not $Quiet) {
        Write-Host "  [WARNING] Error exporting FileGroups: $_" -ForegroundColor Yellow
      }
    }
  }

  # Database Scoped Configurations (folder 02_DatabaseConfiguration) - uses StringBuilder
  if (-not (Test-ObjectTypeExcluded -ObjectType 'DatabaseScopedConfigurations')) {
    try {
      if ($Database.DatabaseScopedConfigurations -and $Database.DatabaseScopedConfigurations.Count -gt 0) {
        $dbConfigs = @($Database.DatabaseScopedConfigurations)
        $configFilePath = Join-Path $OutputDir '02_DatabaseConfiguration' '001_DatabaseScopedConfigurations.sql'
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

        # Ensure directory exists
        $configDir = Split-Path $configFilePath -Parent
        if (-not (Test-Path $configDir)) {
          New-Item -ItemType Directory -Path $configDir -Force | Out-Null
        }

        $configScript.ToString() | Out-File -FilePath $configFilePath -Encoding UTF8
        $results.DatabaseScopedConfigurations = $dbConfigs.Count
        if (-not $Quiet) {
          Write-Host "  [SUCCESS] Exported $($dbConfigs.Count) database scoped configuration(s)" -ForegroundColor Green
        }
      }
    }
    catch {
      if (-not $Quiet) {
        Write-Host "  [WARNING] Error exporting DatabaseScopedConfigurations: $_" -ForegroundColor Yellow
      }
    }
  }

  # Database Scoped Credentials (folder 02_DatabaseConfiguration)
  # SECURITY: Export structure only - secrets cannot be exported safely
  if (-not (Test-ObjectTypeExcluded -ObjectType 'DatabaseScopedCredentials')) {
    try {
      if ($Database.DatabaseScopedCredentials -and $Database.DatabaseScopedCredentials.Count -gt 0) {
        $dbScopedCreds = @($Database.DatabaseScopedCredentials)
        $credFilePath = Join-Path $OutputDir '02_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
        $credScript = New-Object System.Text.StringBuilder
        [void]$credScript.AppendLine("-- Database Scoped Credentials (Structure Only)")
        [void]$credScript.AppendLine("-- WARNING: Secrets cannot be exported and must be provided during import")
        [void]$credScript.AppendLine("-- This file documents the credential names and identities for reference")
        [void]$credScript.AppendLine("")

        foreach ($cred in $dbScopedCreds) {
          $safeIdentity = $cred.Identity -replace "'", "''"
          [void]$credScript.AppendLine("-- Credential: $($cred.Name)")
          [void]$credScript.AppendLine("-- Identity: $($cred.Identity)")
          [void]$credScript.AppendLine("-- MANUAL ACTION REQUIRED: Create this credential with appropriate secret")
          [void]$credScript.AppendLine("-- Example:")
          [void]$credScript.AppendLine("/*")
          [void]$credScript.AppendLine("CREATE DATABASE SCOPED CREDENTIAL [$($cred.Name)]")
          [void]$credScript.AppendLine("WITH IDENTITY = '$safeIdentity',")
          [void]$credScript.AppendLine("SECRET = '<PROVIDE_SECRET_HERE>';")
          [void]$credScript.AppendLine("GO")
          [void]$credScript.AppendLine("*/")
          [void]$credScript.AppendLine("")
        }

        # Ensure directory exists
        $credDir = Split-Path $credFilePath -Parent
        if (-not (Test-Path $credDir)) {
          New-Item -ItemType Directory -Path $credDir -Force | Out-Null
        }

        $credScript.ToString() | Out-File -FilePath $credFilePath -Encoding UTF8
        $results.DatabaseScopedCredentials = $dbScopedCreds.Count
        if (-not $Quiet) {
          Write-Host "  [SUCCESS] Documented $($dbScopedCreds.Count) database scoped credential(s) (structure only)" -ForegroundColor Green
          Write-Host "  [WARNING] Credentials exported as documentation only - secrets must be provided manually" -ForegroundColor Yellow
        }
      }
    }
    catch {
      if (-not $Quiet) {
        Write-Host "  [WARNING] Error exporting DatabaseScopedCredentials: $_" -ForegroundColor Yellow
      }
    }
  }

  return $results
}

function Invoke-ParallelExport {
  <#
  .SYNOPSIS
  Main parallel export orchestrator - executes the parallel export workflow.

  .DESCRIPTION
  Coordinates the entire parallel export process:
  1. Exports non-parallelizable objects sequentially (FileGroups, DatabaseScopedConfigs, DatabaseScopedCredentials)
  2. Builds parallel work queue for all other object types
  3. Creates concurrent collections for results/errors
  4. Initializes runspace pool with configured worker count
  5. Spawns workers and distributes work items
  6. Monitors progress with periodic updates
  7. Aggregates results and reports errors

  .PARAMETER Database
  The SMO Database object to export from.

  .PARAMETER Scripter
  The SMO Scripter object configured with server connection.

  .PARAMETER OutputDir
  The output directory where scripts will be exported.

  .PARAMETER TargetVersion
  The target SQL Server version for script compatibility.

  .OUTPUTS
  System.Collections.Hashtable
  Export summary with TotalItems, SuccessCount, ErrorCount, Errors array, Duration.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [Microsoft.SqlServer.Management.Smo.Database]$Database,

    [Parameter(Mandatory)]
    [Microsoft.SqlServer.Management.Smo.Scripter]$Scripter,

    [Parameter(Mandatory)]
    [string]$OutputDir,

    [Parameter(Mandatory)]
    [string]$TargetVersion
  )

  Write-Host "[INFO] Starting parallel export with $script:ParallelMaxWorkers workers..." -ForegroundColor Cyan
  $exportStartTime = Get-Date

  #region Export Non-Parallelizable Objects Sequentially
  Write-Host "`n[INFO] Exporting non-parallelizable objects sequentially..." -ForegroundColor Cyan

  # Call shared function for FileGroups, DatabaseScopedConfigurations, DatabaseScopedCredentials
  $nonParallelResults = Export-NonParallelizableObjects -Database $Database -OutputDir $OutputDir

  #endregion

  #region Build Parallel Work Queue
  $workQueue = Build-ParallelWorkQueue -Database $Database -OutputDir $OutputDir

  if ($workQueue.Count -eq 0) {
    Write-Host "[WARNING] No work items generated for parallel processing" -ForegroundColor Yellow
    return @{
      TotalItems   = 0
      SuccessCount = 0
      ErrorCount   = 0
      Errors       = @()
      Duration     = (Get-Date) - $exportStartTime
    }
  }
  #endregion

  #region Initialize Concurrent Collections
  $completedItems = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
  $errorItems = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
  $completedCount = [ref]0

  # Convert ArrayList to ConcurrentQueue for thread-safe access
  $concurrentQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()

  # Handle ArrayList enumeration quirks - use indexed access to avoid DictionaryEntry issues
  $count = $workQueue.Count
  for ($i = 0; $i -lt $count; $i++) {
    $item = $workQueue[$i]
    if ($item -is [hashtable]) {
      $concurrentQueue.Enqueue($item)
    }
    else {
      Write-Host "[WARNING] Skipping work item $i of unexpected type: $($item.GetType().FullName)" -ForegroundColor Yellow
    }
  }

  if ($concurrentQueue.Count -ne $workQueue.Count) {
    Write-Host "[WARNING] Only enqueued $($concurrentQueue.Count) of $($workQueue.Count) work items!" -ForegroundColor Yellow
  }
  #endregion

  #region Initialize Runspace Pool
  $runspacePool = Initialize-ParallelRunspacePool -MaxWorkers $script:ParallelMaxWorkers
  if (-not $runspacePool) {
    throw "Failed to initialize runspace pool"
  }
  #endregion

  #region Start Workers
  try {
    Write-Host "[INFO] Starting $script:ParallelMaxWorkers worker(s) for $($workQueue.Count) work items..." -ForegroundColor Cyan

    $workers = Start-ParallelWorkers `
      -RunspacePool $runspacePool `
      -WorkerCount $script:ParallelMaxWorkers `
      -WorkQueue $concurrentQueue `
      -ProgressCounter $completedCount `
      -ResultsBag $completedItems `
      -ConnectionInfo $script:ConnectionInfo `
      -TargetVersion $TargetVersion

    if ($workers.Count -eq 0) {
      throw "No workers were started"
    }

    Write-Host "[SUCCESS] Started $($workers.Count) worker(s)" -ForegroundColor Green

    # Wait for completion with progress monitoring
    Wait-ParallelWorkers `
      -Workers $workers `
      -ProgressCounter $completedCount `
      -TotalItems $workQueue.Count `
      -ProgressInterval $script:ParallelProgressInterval

  }
  finally {
    # Cleanup
    if ($runspacePool) {
      $runspacePool.Close()
      $runspacePool.Dispose()
    }
  }
  #endregion

  #region Aggregate Results
  $exportEndTime = Get-Date
  $duration = $exportEndTime - $exportStartTime

  # Separate successful and failed items from completedItems
  # Worker errors are stored in completedItems with Success=false flag
  $successCount = 0
  foreach ($item in $completedItems) {
    if ($item.Success -eq $false) {
      $errorItems.Add($item)
    }
    else {
      $successCount++
    }
  }

  $summary = @{
    TotalItems   = $workQueue.Count
    SuccessCount = $successCount
    ErrorCount   = $errorItems.Count
    Errors       = @($errorItems | ForEach-Object { $_ })
    Duration     = $duration
  }

  Write-Host "`n[SUCCESS] Parallel export completed in $($duration.TotalSeconds.ToString('F2')) seconds" -ForegroundColor Green
  Write-Host "  Total Items: $($summary.TotalItems)" -ForegroundColor Cyan
  Write-Host "  Successful: $($summary.SuccessCount)" -ForegroundColor Green
  Write-Host "  Errors: $($summary.ErrorCount)" -ForegroundColor $(if ($summary.ErrorCount -gt 0) { 'Red' } else { 'Green' })

  if ($summary.ErrorCount -gt 0) {
    Write-Host "`n[ERROR] The following errors occurred during parallel export:" -ForegroundColor Red
    foreach ($err in $summary.Errors) {
      Write-Host "  $($err.ObjectType) - $($err.OutputPath): $($err.Error)" -ForegroundColor Red
    }
  }

  return $summary
  #endregion
}



#endregion PARALLEL EXPORT FUNCTIONS

$script:LogFile = $null  # Will be set after output directory is created
$script:VerboseOutput = $PSBoundParameters.ContainsKey('Verbose')  # Default is quiet; -Verbose shows per-object progress

# Parallel export settings
$script:ParallelEnabled = $false
$script:ParallelMaxWorkers = 5
$script:ParallelProgressInterval = 50
$script:ConnectionInfo = $null
$script:Config = @{}  # Will be set after config file is loaded

# Export metadata tracking for delta export feature
# This tracks all objects exported for use in incremental/delta exports
$script:ExportMetadata = @{
  Version               = '1.0'
  ExportStartTimeUtc    = $null
  ExportStartTimeServer = $null
  ServerName            = $null
  DatabaseName          = $null
  GroupBy               = 'single'
  IncludeData           = $false
  ObjectTypes           = @{}
  Objects               = [System.Collections.ArrayList]::new()
  FileGroups            = [System.Collections.ArrayList]::new()  # Original file size/growth values
}

# Delta export state (set when -DeltaFrom is used)
$script:DeltaExportEnabled = $false
$script:DeltaMetadata = $null
$script:DeltaFromPath = $null
$script:DeltaChangeResults = $null

# Performance metrics tracking
$script:Metrics = @{
  StartTime            = $null
  EndTime              = $null
  TotalDurationMs      = 0
  ConnectionTimeMs     = 0
  Categories           = [ordered]@{}
  ObjectCounts         = [ordered]@{}
  TotalObjectsExported = 0
  TotalFilesCreated    = 0
  Errors               = 0
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
    DurationMs     = $Timer.ElapsedMilliseconds
    ObjectCount    = $ObjectCount
    SuccessCount   = $SuccessCount
    FailCount      = $FailCount
    AvgMsPerObject = if ($ObjectCount -gt 0) { [math]::Round($Timer.ElapsedMilliseconds / $ObjectCount, 2) } else { 0 }
  }

  $script:Metrics.TotalObjectsExported += $SuccessCount
  $script:Metrics.Errors += $FailCount
}

#region Export Metadata Functions

function Initialize-ExportMetadata {
  <#
    .SYNOPSIS
        Initializes export metadata tracking at the start of an export.
    .DESCRIPTION
        Captures server timestamps (both UTC and server local time) and
        initializes the objects collection for tracking exported items.
        This metadata is used for delta/incremental exports.
    .PARAMETER Database
        The SMO Database object being exported.
    .PARAMETER ServerName
        The server name for metadata.
    .PARAMETER DatabaseName
        The database name for metadata.
    .PARAMETER IncludeData
        Whether data export is enabled.
  #>
  param(
    [Parameter(Mandatory)]
    $Database,
    [Parameter(Mandatory)]
    [string]$ServerName,
    [Parameter(Mandatory)]
    [string]$DatabaseName,
    [bool]$IncludeData = $false
  )

  # Get server time (for modify_date comparison in delta exports)
  # SQL Server stores modify_date in server local time
  $serverTimeQuery = "SELECT GETDATE() AS ServerTime, GETUTCDATE() AS UtcTime"
  try {
    $result = $Database.ExecuteWithResults($serverTimeQuery)
    if ($result.Tables.Count -gt 0 -and $result.Tables[0].Rows.Count -gt 0) {
      $script:ExportMetadata.ExportStartTimeServer = $result.Tables[0].Rows[0]['ServerTime'].ToString('yyyy-MM-ddTHH:mm:ss.fff')
      $script:ExportMetadata.ExportStartTimeUtc = $result.Tables[0].Rows[0]['UtcTime'].ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
    else {
      # Fallback to local time if query fails
      $now = Get-Date
      $script:ExportMetadata.ExportStartTimeServer = $now.ToString('yyyy-MM-ddTHH:mm:ss.fff')
      $script:ExportMetadata.ExportStartTimeUtc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    }
  }
  catch {
    # Fallback to local time if query fails
    $now = Get-Date
    $script:ExportMetadata.ExportStartTimeServer = $now.ToString('yyyy-MM-ddTHH:mm:ss.fff')
    $script:ExportMetadata.ExportStartTimeUtc = $now.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ss.fffZ')
    Write-Verbose "Could not get server time, using local time: $_"
  }

  $script:ExportMetadata.ServerName = $ServerName
  $script:ExportMetadata.DatabaseName = $DatabaseName
  $script:ExportMetadata.IncludeData = $IncludeData
  $script:ExportMetadata.Objects = [System.Collections.ArrayList]::new()
  $script:ExportMetadata.FileGroups = [System.Collections.ArrayList]::new()

  # Determine groupBy setting from config
  $groupBy = 'single'  # Default
  if ($script:Config -and $script:Config.ContainsKey('export')) {
    $exportConfig = $script:Config['export']
    if ($exportConfig -and $exportConfig.ContainsKey('groupBy')) {
      $groupBy = $exportConfig['groupBy']
    }
  }
  $script:ExportMetadata.GroupBy = $groupBy
}

function Add-ExportedObject {
  <#
    .SYNOPSIS
        Records an exported object in the metadata.
    .DESCRIPTION
        Adds an entry to the Objects collection tracking what was exported.
        This is used by delta exports to determine what changed.
    .PARAMETER Type
        The object type (Table, View, StoredProcedure, etc.)
    .PARAMETER Schema
        The schema name (null for schema-less objects like FileGroups)
    .PARAMETER Name
        The object name.
    .PARAMETER FilePath
        The relative file path within the export folder.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$Type,
    [string]$Schema,
    [Parameter(Mandatory)]
    [string]$Name,
    [Parameter(Mandatory)]
    [string]$FilePath
  )

  $entry = [ordered]@{
    type     = $Type
    schema   = $Schema
    name     = $Name
    filePath = $FilePath
  }

  [void]$script:ExportMetadata.Objects.Add($entry)
}

function Save-ExportMetadata {
  <#
    .SYNOPSIS
        Writes the export metadata to _export_metadata.json.
    .DESCRIPTION
        Serializes the collected metadata to JSON format and saves
        it to the export directory. This file is required for delta exports.
    .PARAMETER OutputDir
        The export output directory.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$OutputDir
  )

  $metadataPath = Join-Path $OutputDir '_export_metadata.json'

  # Build object list by scanning exported files
  # This approach captures all exported objects regardless of export path (sequential/parallel)
  $objects = [System.Collections.ArrayList]::new()

  # Map folder names to object types
  $folderTypeMap = @{
    '00_FileGroups'            = 'FileGroup'
    '01_Security'              = 'Security'
    '02_DatabaseConfiguration' = 'DatabaseConfiguration'
    '03_Schemas'               = 'Schema'
    '04_Sequences'             = 'Sequence'
    '05_PartitionFunctions'    = 'PartitionFunction'
    '06_PartitionSchemes'      = 'PartitionScheme'
    '07_Types'                 = 'UserDefinedType'
    '08_XmlSchemaCollections'  = 'XmlSchemaCollection'
    '09_Tables_PrimaryKey'     = 'Table'
    '10_Tables_ForeignKeys'    = 'ForeignKey'
    '11_Indexes'               = 'Index'
    '12_Defaults'              = 'Default'
    '13_Rules'                 = 'Rule'
    '14_Programmability'       = 'Programmability'
    '15_Synonyms'              = 'Synonym'
    '16_FullTextSearch'        = 'FullTextCatalog'
    '17_ExternalData'          = 'ExternalData'
    '18_SearchPropertyLists'   = 'SearchPropertyList'
    '19_PlanGuides'            = 'PlanGuide'
    '20_SecurityPolicies'      = 'SecurityPolicy'
    '21_Data'                  = 'Data'
  }

  # Scan each numbered folder
  $folders = Get-ChildItem -Path $OutputDir -Directory | Where-Object { $_.Name -match '^\d{2}_' }

  foreach ($folder in $folders) {
    $objectType = if ($folderTypeMap.ContainsKey($folder.Name)) { $folderTypeMap[$folder.Name] } else { $folder.Name -replace '^\d{2}_', '' }

    # Get all SQL files in this folder
    $sqlFiles = Get-ChildItem -Path $folder.FullName -Filter '*.sql' -Recurse

    foreach ($file in $sqlFiles) {
      # Parse schema.name from filename (e.g., "dbo.Customers.sql" -> schema=dbo, name=Customers)
      $baseName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
      $schema = $null
      $name = $baseName

      # Try to parse schema.name pattern
      if ($baseName -match '^([^.]+)\.(.+)$') {
        $schema = $matches[1]
        $name = $matches[2]
      }

      # Build relative path from export root
      $relativePath = $file.FullName.Substring($OutputDir.Length).TrimStart('\', '/')

      $entry = [ordered]@{
        type     = $objectType
        schema   = $schema
        name     = $name
        filePath = $relativePath
      }

      [void]$objects.Add($entry)
    }
  }

  # Build the final metadata object
  $metadata = [ordered]@{
    version               = $script:ExportMetadata.Version
    exportStartTimeUtc    = $script:ExportMetadata.ExportStartTimeUtc
    exportStartTimeServer = $script:ExportMetadata.ExportStartTimeServer
    serverName            = $script:ExportMetadata.ServerName
    databaseName          = $script:ExportMetadata.DatabaseName
    groupBy               = $script:ExportMetadata.GroupBy
    includeData           = $script:ExportMetadata.IncludeData
    objectCount           = $objects.Count
    objects               = $objects
  }

  # Add fileGroups metadata if any were exported (contains original size/growth values)
  if ($script:ExportMetadata.FileGroups -and $script:ExportMetadata.FileGroups.Count -gt 0) {
    $metadata.fileGroups = $script:ExportMetadata.FileGroups
  }

  # Convert to JSON with proper formatting
  $json = $metadata | ConvertTo-Json -Depth 10

  # Write to file
  $json | Out-File -FilePath $metadataPath -Encoding UTF8

  Write-Output "[SUCCESS] Export metadata saved: _export_metadata.json ($($objects.Count) objects tracked)"
}

function Read-ExportMetadata {
  <#
    .SYNOPSIS
        Reads and parses export metadata from a previous export.
    .DESCRIPTION
        Loads the _export_metadata.json file from a previous export directory
        and returns the parsed metadata object. Used for delta export validation
        and change detection.
    .PARAMETER ExportPath
        Path to the previous export directory.
    .OUTPUTS
        Hashtable containing the parsed metadata, or $null if not found.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$ExportPath
  )

  $metadataPath = Join-Path $ExportPath '_export_metadata.json'

  if (-not (Test-Path $metadataPath)) {
    return $null
  }

  try {
    $json = Get-Content -Path $metadataPath -Raw -Encoding UTF8
    $metadata = $json | ConvertFrom-Json -AsHashtable
    return $metadata
  }
  catch {
    Write-Warning "Failed to parse metadata file: $_"
    return $null
  }
}

function Test-DeltaExportCompatibility {
  <#
    .SYNOPSIS
        Validates that delta export can proceed with the given configuration.
    .DESCRIPTION
        Checks that the previous export exists, has valid metadata, uses
        groupBy:single mode, and optionally warns about server/database mismatches.
        Delta export requires groupBy:single because grouped files cannot be
        merged incrementally.
    .PARAMETER DeltaFromPath
        Path to the previous export directory.
    .PARAMETER CurrentConfig
        The current export configuration hashtable.
    .PARAMETER CurrentServerName
        The current server being exported.
    .PARAMETER CurrentDatabaseName
        The current database being exported.
    .OUTPUTS
        Hashtable with:
          - IsValid: $true if delta export can proceed
          - Metadata: The previous export metadata (if valid)
          - Errors: Array of error messages (if invalid)
          - Warnings: Array of warning messages
  #>
  param(
    [Parameter(Mandatory)]
    [string]$DeltaFromPath,
    [hashtable]$CurrentConfig,
    [string]$CurrentServerName,
    [string]$CurrentDatabaseName
  )

  $result = @{
    IsValid  = $true
    Metadata = $null
    Errors   = [System.Collections.ArrayList]::new()
    Warnings = [System.Collections.ArrayList]::new()
  }

  # Check 1: Previous export path exists
  if (-not (Test-Path $DeltaFromPath)) {
    [void]$result.Errors.Add("Delta export source path does not exist: $DeltaFromPath")
    $result.IsValid = $false
    return $result
  }

  # Check 2: Metadata file exists and is valid
  $metadata = Read-ExportMetadata -ExportPath $DeltaFromPath
  if ($null -eq $metadata) {
    [void]$result.Errors.Add("Previous export is missing _export_metadata.json file. Delta export requires metadata from the base export. The base export may be from an older version that did not generate metadata.")
    $result.IsValid = $false
    return $result
  }
  $result.Metadata = $metadata

  # Check 3: Previous export used groupBy: single
  $previousGroupBy = if ($metadata.ContainsKey('groupBy')) { $metadata['groupBy'] } else { 'single' }
  if ($previousGroupBy -ne 'single') {
    [void]$result.Errors.Add("Previous export used groupBy: '$previousGroupBy'. Delta export requires groupBy: single in both exports.")
    $result.IsValid = $false
  }

  # Check 4: Current config uses groupBy: single (or default)
  $currentGroupBy = 'single'  # Default
  if ($CurrentConfig -and $CurrentConfig.ContainsKey('export')) {
    $exportConfig = $CurrentConfig['export']
    if ($exportConfig -and $exportConfig.ContainsKey('groupBy')) {
      $currentGroupBy = $exportConfig['groupBy']
    }
  }
  if ($currentGroupBy -ne 'single') {
    [void]$result.Errors.Add("Current config uses groupBy: '$currentGroupBy'. Delta export requires groupBy: single.")
    $result.IsValid = $false
  }

  # Check 5: Server/database match (warning only, not blocking)
  $previousServer = if ($metadata.ContainsKey('serverName')) { $metadata['serverName'] } else { '' }
  $previousDb = if ($metadata.ContainsKey('databaseName')) { $metadata['databaseName'] } else { '' }

  if ($CurrentServerName -and $previousServer -and ($previousServer -ne $CurrentServerName)) {
    [void]$result.Warnings.Add("Server name mismatch: previous='$previousServer', current='$CurrentServerName'. Proceeding with delta export.")
  }
  if ($CurrentDatabaseName -and $previousDb -and ($previousDb -ne $CurrentDatabaseName)) {
    [void]$result.Warnings.Add("Database name mismatch: previous='$previousDb', current='$CurrentDatabaseName'. Proceeding with delta export.")
  }

  return $result
}

function Get-DatabaseObjectsWithModifyDate {
  <#
    .SYNOPSIS
        Queries the database for all objects with their modify_date.
    .DESCRIPTION
        Retrieves current objects from sys.objects with schema name, object name,
        type, and modify_date. Used for delta export change detection.
    .PARAMETER Database
        The SMO Database object to query.
    .OUTPUTS
        Hashtable keyed by "Type|Schema|Name" containing object info.
  #>
  param(
    [Parameter(Mandatory)]
    $Database
  )

  $query = @"
SELECT
    ISNULL(s.name, '') AS SchemaName,
    o.name AS ObjectName,
    o.type AS TypeCode,
    o.type_desc AS TypeDesc,
    o.modify_date AS ModifyDate
FROM sys.objects o
LEFT JOIN sys.schemas s ON o.schema_id = s.schema_id
WHERE o.is_ms_shipped = 0
  AND o.type IN ('U', 'V', 'P', 'FN', 'IF', 'TF', 'TR', 'SN', 'SO')
ORDER BY o.type_desc, s.name, o.name
"@

  $objects = @{}

  try {
    $result = $Database.ExecuteWithResults($query)
    if ($result.Tables.Count -gt 0) {
      foreach ($row in $result.Tables[0].Rows) {
        # Map SQL Server type codes to our type names
        $typeCode = $row['TypeCode'].ToString().Trim()
        $typeName = switch ($typeCode) {
          'U' { 'Table' }
          'V' { 'View' }
          'P' { 'StoredProcedure' }
          'FN' { 'UserDefinedFunction' }
          'IF' { 'UserDefinedFunction' }
          'TF' { 'UserDefinedFunction' }
          'TR' { 'Trigger' }
          'SN' { 'Synonym' }
          'SO' { 'Sequence' }
          default { $row['TypeDesc'].ToString() }
        }

        $schema = $row['SchemaName'].ToString()
        $name = $row['ObjectName'].ToString()
        $modifyDate = $row['ModifyDate']

        # Key format matches what we use in metadata
        $key = "$typeName|$schema|$name"

        $objects[$key] = @{
          Type       = $typeName
          Schema     = $schema
          Name       = $name
          ModifyDate = $modifyDate
        }
      }
    }
  }
  catch {
    Write-Warning "Failed to query database objects: $_"
  }

  return $objects
}

function Test-SafeRelativePath {
  <#
    .SYNOPSIS
        Validates that a relative path doesn't contain path traversal sequences.
    .DESCRIPTION
        Security check to prevent malicious or corrupted metadata from causing
        file operations outside the intended export directory. Rejects paths
        containing "..", absolute paths, or other traversal attempts.
    .PARAMETER RelativePath
        The relative path to validate.
    .OUTPUTS
        $true if the path is safe, $false otherwise.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$RelativePath
  )

  # Reject empty or null paths
  if ([string]::IsNullOrWhiteSpace($RelativePath)) {
    return $false
  }

  # Reject paths with parent directory traversal sequences
  if ($RelativePath -match '\.\.' -or $RelativePath -match '\.\.\\' -or $RelativePath -match '\.\./') {
    return $false
  }

  # Reject absolute paths (Windows drive letters or UNC paths)
  if ($RelativePath -match '^[A-Za-z]:' -or $RelativePath -match '^\\\\' -or $RelativePath -match '^/') {
    return $false
  }

  # Reject paths with null bytes or other suspicious characters
  if ($RelativePath -match '\x00') {
    return $false
  }

  return $true
}

function Compare-ExportObjects {
  <#
    .SYNOPSIS
        Compares current database objects with previous export metadata.
    .DESCRIPTION
        Determines which objects are modified, new, deleted, or unchanged
        by comparing modify_date with the previous export timestamp.
    .PARAMETER CurrentObjects
        Hashtable of current objects from Get-DatabaseObjectsWithModifyDate.
    .PARAMETER PreviousMetadata
        The previous export metadata hashtable.
    .OUTPUTS
        Hashtable with Modified, New, Deleted, Unchanged, and AlwaysExport arrays.
  #>
  param(
    [Parameter(Mandatory)]
    [hashtable]$CurrentObjects,
    [Parameter(Mandatory)]
    [hashtable]$PreviousMetadata
  )

  $result = @{
    Modified     = [System.Collections.ArrayList]::new()
    New          = [System.Collections.ArrayList]::new()
    Deleted      = [System.Collections.ArrayList]::new()
    Unchanged    = [System.Collections.ArrayList]::new()
    AlwaysExport = [System.Collections.ArrayList]::new()
  }

  # Get previous export timestamp
  $previousTimestamp = $null
  if ($PreviousMetadata.ContainsKey('exportStartTimeServer')) {
    $timestampStr = $PreviousMetadata['exportStartTimeServer']
    try {
      $previousTimestamp = [DateTime]::Parse($timestampStr)
    }
    catch {
      Write-Warning "Could not parse previous export timestamp: $timestampStr"
    }
  }

  # Build a lookup of previous objects by key
  $previousObjects = @{}
  if ($PreviousMetadata.ContainsKey('objects')) {
    foreach ($obj in $PreviousMetadata['objects']) {
      $type = $obj['type']
      $schema = if ($obj['schema']) { $obj['schema'] } else { '' }
      $name = $obj['name']
      $key = "$type|$schema|$name"
      $previousObjects[$key] = $obj
    }
  }

  # Compare current objects with previous
  foreach ($key in $CurrentObjects.Keys) {
    $current = $CurrentObjects[$key]

    if ($previousObjects.ContainsKey($key)) {
      # Object exists in both - check if modified
      $previous = $previousObjects[$key]

      if ($null -eq $previousTimestamp) {
        # No valid timestamp, treat as modified to be safe
        [void]$result.Modified.Add($current)
      }
      elseif ($current.ModifyDate -gt $previousTimestamp) {
        # Modified since last export
        $current['FilePath'] = $previous['filePath']
        [void]$result.Modified.Add($current)
      }
      else {
        # Unchanged
        $current['FilePath'] = $previous['filePath']
        [void]$result.Unchanged.Add($current)
      }
    }
    else {
      # New object (in current, not in previous)
      [void]$result.New.Add($current)
    }
  }

  # Find deleted objects (in previous, not in current)
  foreach ($key in $previousObjects.Keys) {
    if (-not $CurrentObjects.ContainsKey($key)) {
      $previous = $previousObjects[$key]
      [void]$result.Deleted.Add(@{
          Type     = $previous['type']
          Schema   = $previous['schema']
          Name     = $previous['name']
          FilePath = $previous['filePath']
        })
    }
  }

  return $result
}

function Get-AlwaysExportObjectTypes {
  <#
    .SYNOPSIS
        Returns object types that should always be exported (no modify_date tracking).
    .DESCRIPTION
        Some database objects don't have modify_date in sys.objects or are stored
        differently. These should always be re-exported in delta mode.
    .OUTPUTS
        Array of object type names that should always be exported.
  #>

  # These types don't have reliable modify_date or aren't in sys.objects:
  # - FileGroups: Database-level, no modify_date
  # - Schemas: sys.schemas has no modify_date
  # - DatabaseScopedConfigurations: Not in sys.objects
  # - Security objects (Roles, Users): Different tracking
  # - Partition Functions/Schemes: May not have accurate modify_date
  # - XmlSchemaCollections: Separate system table
  # - UserDefinedTypes: sys.types
  # - Defaults/Rules: Legacy objects
  # - FullTextCatalogs/StopLists: Separate tables
  # - Assemblies: sys.assemblies
  # - Certificates/Keys: Security objects
  # - SecurityPolicies: RLS policies
  # - PlanGuides: sys.plan_guides
  # - ExternalData: External sources/formats
  # - Data: Table data changes constantly

  return @(
    'FileGroup',
    'Schema',
    'DatabaseConfiguration',
    'Security',
    'PartitionFunction',
    'PartitionScheme',
    'XmlSchemaCollection',
    'UserDefinedType',
    'Default',
    'Rule',
    'FullTextCatalog',
    'Assembly',
    'Certificate',
    'AsymmetricKey',
    'SymmetricKey',
    'SecurityPolicy',
    'PlanGuide',
    'ExternalData',
    'Data',
    'ForeignKey',  # FKs tracked separately from tables
    'Index'        # Indexes tracked separately from tables
  )
}

function Get-DeltaChangeDetection {
  <#
    .SYNOPSIS
        Performs full delta change detection for an export.
    .DESCRIPTION
        Combines object querying, comparison, and always-export logic to produce
        the final lists of objects to export, copy, and report as deleted.
    .PARAMETER Database
        The SMO Database object to query.
    .PARAMETER PreviousMetadata
        The previous export metadata hashtable.
    .OUTPUTS
        Hashtable with ToExport, ToCopy, Deleted arrays and summary stats.
  #>
  param(
    [Parameter(Mandatory)]
    $Database,
    [Parameter(Mandatory)]
    [hashtable]$PreviousMetadata
  )

  Write-Output "Performing delta change detection..."

  # Get current objects from database
  $currentObjects = Get-DatabaseObjectsWithModifyDate -Database $Database
  Write-Verbose "Found $($currentObjects.Count) objects with modify_date in database"

  # Compare with previous export
  $comparison = Compare-ExportObjects -CurrentObjects $currentObjects -PreviousMetadata $PreviousMetadata

  # Build always-export list from previous metadata
  $alwaysExportTypes = Get-AlwaysExportObjectTypes
  $alwaysExportObjects = [System.Collections.ArrayList]::new()

  if ($PreviousMetadata.ContainsKey('objects')) {
    foreach ($obj in $PreviousMetadata['objects']) {
      $type = $obj['type']
      if ($alwaysExportTypes -contains $type) {
        [void]$alwaysExportObjects.Add(@{
            Type     = $type
            Schema   = $obj['schema']
            Name     = $obj['name']
            FilePath = $obj['filePath']
          })
      }
    }
  }

  # Build final result
  $result = @{
    # Objects to export (modified + new + always-export types)
    ToExport          = [System.Collections.ArrayList]::new()
    # Objects to copy from previous export (unchanged, except always-export types)
    ToCopy            = [System.Collections.ArrayList]::new()
    # Deleted objects (informational)
    Deleted           = $comparison.Deleted
    # Statistics
    ModifiedCount     = $comparison.Modified.Count
    NewCount          = $comparison.New.Count
    DeletedCount      = $comparison.Deleted.Count
    UnchangedCount    = $comparison.Unchanged.Count
    AlwaysExportCount = $alwaysExportObjects.Count
  }

  # Add modified and new to export list
  foreach ($obj in $comparison.Modified) { [void]$result.ToExport.Add($obj) }
  foreach ($obj in $comparison.New) { [void]$result.ToExport.Add($obj) }
  foreach ($obj in $alwaysExportObjects) { [void]$result.ToExport.Add($obj) }

  # Add unchanged to copy list (excluding always-export types which are re-exported)
  foreach ($obj in $comparison.Unchanged) {
    if ($alwaysExportTypes -notcontains $obj.Type) {
      [void]$result.ToCopy.Add($obj)
    }
  }

  # Log summary
  Write-Output "  [INFO] Change detection complete:"
  Write-Output "    Modified: $($comparison.Modified.Count)"
  Write-Output "    New: $($comparison.New.Count)"
  Write-Output "    Deleted: $($comparison.Deleted.Count)"
  Write-Output "    Unchanged: $($comparison.Unchanged.Count)"
  Write-Output "    Always re-export: $($alwaysExportObjects.Count)"
  Write-Output "  [INFO] Will export: $($result.ToExport.Count) objects"
  Write-Output "  [INFO] Will copy: $($result.ToCopy.Count) files from previous export"

  return $result
}

function Copy-UnchangedFiles {
  <#
    .SYNOPSIS
        Copies unchanged files from the previous export to the new export directory.
    .DESCRIPTION
        For delta exports, unchanged objects don't need to be re-exported.
        This function copies their files from the previous export to maintain
        a complete, standalone export folder.
    .PARAMETER ToCopyList
        Array of objects to copy, each with FilePath property.
    .PARAMETER SourceExportPath
        Path to the previous export directory.
    .PARAMETER DestinationExportPath
        Path to the new export directory.
    .OUTPUTS
        Hashtable with CopiedCount, FailedCount, and Errors array.
  #>
  param(
    [Parameter(Mandatory)]
    [array]$ToCopyList,
    [Parameter(Mandatory)]
    [string]$SourceExportPath,
    [Parameter(Mandatory)]
    [string]$DestinationExportPath
  )

  $result = @{
    CopiedCount = 0
    FailedCount = 0
    Errors      = [System.Collections.ArrayList]::new()
  }

  if ($ToCopyList.Count -eq 0) {
    return $result
  }

  Write-Output "Copying $($ToCopyList.Count) unchanged files from previous export..."

  foreach ($obj in $ToCopyList) {
    $filePath = $obj.FilePath
    if (-not $filePath) {
      [void]$result.Errors.Add("Object missing FilePath: $($obj.Type) $($obj.Schema).$($obj.Name)")
      $result.FailedCount++
      continue
    }

    # Security: Validate path doesn't contain traversal sequences
    if (-not (Test-SafeRelativePath -RelativePath $filePath)) {
      [void]$result.Errors.Add("Unsafe FilePath rejected (possible path traversal): $filePath")
      $result.FailedCount++
      continue
    }

    $sourcePath = Join-Path $SourceExportPath $filePath
    $destPath = Join-Path $DestinationExportPath $filePath

    if (-not (Test-Path $sourcePath)) {
      [void]$result.Errors.Add("Source file not found: $sourcePath")
      $result.FailedCount++
      continue
    }

    try {
      # Ensure destination directory exists
      $destDir = Split-Path $destPath -Parent
      if (-not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
      }

      # Copy the file
      Copy-Item -Path $sourcePath -Destination $destPath -Force
      $result.CopiedCount++
    }
    catch {
      [void]$result.Errors.Add("Failed to copy $filePath : $_")
      $result.FailedCount++
    }
  }

  Write-Output "  [SUCCESS] Copied $($result.CopiedCount) file(s)"
  if ($result.FailedCount -gt 0) {
    Write-Host "  [WARNING] Failed to copy $($result.FailedCount) file(s)" -ForegroundColor Yellow
    foreach ($err in $result.Errors) {
      Write-Verbose "    $err"
    }
  }

  return $result
}

# Delta export lookup hashtable (built once, used for O(1) lookups)
$script:DeltaExportLookup = $null

function Initialize-DeltaExportLookup {
  <#
    .SYNOPSIS
        Builds a hashtable for fast O(1) lookups during delta export filtering.
    .DESCRIPTION
        Creates a lookup table keyed by "Type|Schema|Name" for objects that need
        to be exported (modified, new, or always-export types). Called once after
        change detection, before export begins.
  #>

  if (-not $script:DeltaExportEnabled -or -not $script:DeltaChangeResults) {
    $script:DeltaExportLookup = $null
    return
  }

  $script:DeltaExportLookup = @{}

  foreach ($obj in $script:DeltaChangeResults.ToExport) {
    $type = $obj.Type
    $schema = if ($obj.Schema) { $obj.Schema } else { '' }
    $name = $obj.Name
    $key = "$type|$schema|$name"
    $script:DeltaExportLookup[$key] = $true
  }

  Write-Verbose "Delta export lookup initialized with $($script:DeltaExportLookup.Count) objects to export"
}

function Test-ShouldExportInDelta {
  <#
    .SYNOPSIS
        Checks if an object should be exported in delta mode.
    .DESCRIPTION
        Returns $true if delta export is disabled (export everything) or if the
        object is in the ToExport list (modified/new/always-export).
        Returns $false if the object is unchanged and should be copied instead.
    .PARAMETER ObjectType
        The type of object (Table, View, StoredProcedure, etc.).
    .PARAMETER Schema
        The schema name (may be empty for schema-less objects).
    .PARAMETER Name
        The object name.
    .OUTPUTS
        $true if the object should be exported, $false if it should be skipped.
  #>
  param(
    [Parameter(Mandatory)]
    [string]$ObjectType,
    [string]$Schema = '',
    [Parameter(Mandatory)]
    [string]$Name
  )

  # If delta export is not enabled, export everything
  if (-not $script:DeltaExportEnabled) {
    return $true
  }

  # If no lookup table (shouldn't happen), export everything to be safe
  if ($null -eq $script:DeltaExportLookup) {
    return $true
  }

  # Check if object is in the ToExport list
  $key = "$ObjectType|$Schema|$Name"
  return $script:DeltaExportLookup.ContainsKey($key)
}

function Get-DeltaFilteredCollection {
  <#
    .SYNOPSIS
        Filters a collection to only include objects that should be exported in delta mode.
    .DESCRIPTION
        When delta export is enabled, filters out unchanged objects that will be
        copied from the previous export. When disabled, returns the full collection.
        This provides significant performance improvement by avoiding SMO scripting
        for unchanged objects.
    .PARAMETER Collection
        The collection of SMO objects to filter.
    .PARAMETER ObjectType
        The delta export type name (Table, View, StoredProcedure, etc.).
    .PARAMETER SchemaProperty
        The property name containing the schema (default: 'Schema').
        Set to $null for schema-less objects.
    .PARAMETER NameProperty
        The property name containing the object name (default: 'Name').
    .OUTPUTS
        Filtered array of objects to export.
  #>
  param(
    [Parameter(Mandatory)]
    [AllowEmptyCollection()]
    [array]$Collection,
    [Parameter(Mandatory)]
    [string]$ObjectType,
    [string]$SchemaProperty = 'Schema',
    [string]$NameProperty = 'Name'
  )

  # Handle empty collection gracefully
  if ($null -eq $Collection -or $Collection.Count -eq 0) {
    return @()
  }

  # If delta export is not enabled, return full collection
  if (-not $script:DeltaExportEnabled) {
    return $Collection
  }

  # Filter collection to only objects in ToExport list
  $filtered = @()
  $skippedCount = 0

  foreach ($obj in $Collection) {
    $schema = if ($SchemaProperty -and $obj.PSObject.Properties[$SchemaProperty]) {
      $obj.$SchemaProperty
    }
    else {
      ''
    }
    $name = $obj.$NameProperty

    if (Test-ShouldExportInDelta -ObjectType $ObjectType -Schema $schema -Name $name) {
      $filtered += $obj
    }
    else {
      $skippedCount++
    }
  }

  if ($skippedCount -gt 0) {
    Write-Verbose "  [DELTA] Skipping $skippedCount unchanged $ObjectType object(s)"
  }

  return $filtered
}

#endregion Export Metadata Functions

function Write-ObjectProgress {
  <#
    .SYNOPSIS
        Writes progress for an object export. Default shows milestone progress; -Verbose shows every object.
    .DESCRIPTION
        Reduces console I/O overhead by batching progress output.
        Default mode writes at 10% intervals. With -Verbose, writes every object.
    #>
  param(
    [string]$ObjectName,
    [int]$Current,
    [int]$Total,
    [switch]$Success,
    [switch]$Failed
  )

  $percentComplete = [math]::Floor(($Current / $Total) * 100)

  $labelPrefix = if ($script:CurrentProgressLabel) { "$($script:CurrentProgressLabel) " } else { '' }

  if ($script:VerboseOutput) {
    # Verbose mode - show every object with SUCCESS/FAILED status
    # Only print object name on initial call (no Success/Failed flag)
    if (-not $Success -and -not $Failed) {
      Write-Host ("  [{0,3}%]{1}{2}..." -f $percentComplete, $labelPrefix, $ObjectName)
    }
    elseif ($Success) {
      Write-Host "        [SUCCESS]" -ForegroundColor Green
    }
    elseif ($Failed) {
      Write-Host "        [FAILED]" -ForegroundColor Red
    }
  }
  else {
    # Default mode - only show progress at 10% intervals or for failures
    # Skip the -Success calls entirely - we already showed progress at milestone
    if ($Success) { return }

    $milestone = [math]::Floor($percentComplete / 10) * 10
    $prevMilestone = if ($Current -gt 1) { [math]::Floor((($Current - 1) / $Total) * 100 / 10) * 10 } else { -1 }

    if ($Failed) {
      # Always show failures with object context
      Write-Host ("  [{0,3}%] FAILED {1}{2}" -f $percentComplete, $labelPrefix, $ObjectName) -ForegroundColor Red
    }
    elseif ($milestone -gt $prevMilestone -or $Current -eq $Total) {
      # Show at milestones (10%, 20%, etc.) and at completion
      Write-Host ("  [{0,3}%]" -f $percentComplete)
    }
  }
}

function Write-ProgressHeader {
  <#
    .SYNOPSIS
        Writes a one-time progress header for a section and sets the progress label.
    #>
  param(
    [string]$Label
  )

  if ([string]::IsNullOrWhiteSpace($Label)) { return }

  if ($script:LastProgressLabel -ne $Label) {
    Write-Host "== $Label ==" -ForegroundColor Gray
    $script:LastProgressLabel = $Label
  }

  $script:CurrentProgressLabel = $Label
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
    }
    else { 0 }

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
    ExportDate            = $script:Metrics.StartTime.ToString('yyyy-MM-dd HH:mm:ss')
    TotalDurationSeconds  = [math]::Round($script:Metrics.TotalDurationMs / 1000, 2)
    ConnectionTimeSeconds = [math]::Round($script:Metrics.ConnectionTimeMs / 1000, 2)
    ExportTimeSeconds     = [math]::Round(($script:Metrics.TotalDurationMs - $script:Metrics.ConnectionTimeMs) / 1000, 2)
    TotalObjectsExported  = $script:Metrics.TotalObjectsExported
    TotalFilesCreated     = $script:Metrics.TotalFilesCreated
    Errors                = $script:Metrics.Errors
    Categories            = @{}
  }

  foreach ($cat in $script:Metrics.Categories.GetEnumerator()) {
    $metricsJson.Categories[$cat.Key] = @{
      DurationSeconds = [math]::Round($cat.Value.DurationMs / 1000, 3)
      ObjectCount     = $cat.Value.ObjectCount
      SuccessCount    = $cat.Value.SuccessCount
      FailCount       = $cat.Value.FailCount
      AvgMsPerObject  = $cat.Value.AvgMsPerObject
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
    'ERROR' { Write-Host $Message -ForegroundColor Red }
    default { Write-Output $Message }
  }

  # Also write to log file if available
  if ($script:LogFile -and (Test-Path (Split-Path $script:LogFile -Parent))) {
    try {
      Add-Content -Path $script:LogFile -Value $logEntry -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
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
    }
    else {
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
    }
    catch {
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
    }
    else {
      # Fallback to direct assembly load
      Add-Type -AssemblyName 'Microsoft.SqlServer.Smo' -ErrorAction Stop
      Write-Output '[SUCCESS] SQL Server Management Objects (SMO) available'
    }
  }
  catch {
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
    }
    else {
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
  }
  catch {
    Write-Error "[ERROR] Connection failed: $_"
    return $false
  }
  finally {
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
    '01_Security',
    '02_DatabaseConfiguration',
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
    '14_Programmability/01_Assemblies',
    '14_Programmability/02_Functions',
    '14_Programmability/03_StoredProcedures',
    '14_Programmability/04_Triggers',
    '14_Programmability/05_Views',
    '15_Synonyms',
    '16_FullTextSearch',
    '17_ExternalData',
    '18_SearchPropertyLists',
    '19_PlanGuides',
    '20_SecurityPolicies',
    '21_Data'
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
    if (-not $config.export.includeObjectTypes) {
      $config.export.includeObjectTypes = @()
    }
    if (-not $config.export.excludeObjectTypes) {
      $config.export.excludeObjectTypes = @()
    }

    # Command-line IncludeObjectTypes overrides config file
    if ($IncludeObjectTypes -and $IncludeObjectTypes.Count -gt 0) {
      $config.export.includeObjectTypes = $IncludeObjectTypes
      Write-Verbose "Command-line override: IncludeObjectTypes = $($IncludeObjectTypes -join ', ')"
    }

    # Command-line ExcludeObjectTypes overrides config file
    if ($ExcludeObjectTypes -and $ExcludeObjectTypes.Count -gt 0) {
      $config.export.excludeObjectTypes = $ExcludeObjectTypes
      Write-Verbose "Command-line override: ExcludeObjectTypes = $($ExcludeObjectTypes -join ', ')"
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
    if (-not $config.export.groupByObjectTypes) {
      $config.export.groupByObjectTypes = @{}
    }

    Write-Host "[SUCCESS] Configuration loaded successfully" -ForegroundColor Green
    return $config

  }
  catch {
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

  # Show included/excluded object types
  if ($Config.export -and $Config.export.includeObjectTypes -and $Config.export.includeObjectTypes.Count -gt 0) {
    Write-Host "Included Object Types (whitelist): " -NoNewline -ForegroundColor Gray
    Write-Host ($Config.export.includeObjectTypes -join ", ") -ForegroundColor Cyan
  }
  elseif ($Config.export -and $Config.export.excludeObjectTypes -and $Config.export.excludeObjectTypes.Count -gt 0) {
    Write-Host "Excluded Object Types: " -NoNewline -ForegroundColor Gray
    Write-Host ($Config.export.excludeObjectTypes -join ", ") -ForegroundColor Yellow
  }
  else {
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

  if ($Config.export -and $Config.export.includeObjectTypes -and $Config.export.includeObjectTypes.Count -gt 0) {
    Write-Host "[INCLUDE ONLY] $($Config.export.includeObjectTypes -join ', ')" -ForegroundColor Cyan
  }
  elseif ($Config.export -and $Config.export.excludeObjectTypes -and $Config.export.excludeObjectTypes.Count -gt 0) {
    Write-Host "[ENABLED] All object types exported by default" -ForegroundColor Green
    Write-Host "[EXCLUDED] $($Config.export.excludeObjectTypes -join ', ')" -ForegroundColor Yellow
  }
  else {
    Write-Host "[ENABLED] All object types exported by default" -ForegroundColor Green
  }

  if ($DataExport) {
    Write-Host "[ENABLED] Data export" -ForegroundColor Green
  }
  else {
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
    AllowSystemObjects       = $false
    AnsiFile                 = $true
    AnsiPadding              = $true
    AppendToFile             = $false
    ContinueScriptingOnError = $true
    TargetServerVersion      = $TargetVersion
    ToFileOnly               = $true
    IncludeHeaders           = $false
    DriAll                   = $true
    Indexes                  = $true
    Triggers                 = $true
    Permissions              = $true
    ExtendedProperties       = $true
    ChangeTracking           = $true
    Bindings                 = $true
    ClusteredIndexes         = $true
    NonClusteredIndexes      = $true
    XmlIndexes               = $true
    FullTextIndexes          = $true
    FullTextCatalogs         = $true
    FullTextStopLists        = $true
    ScriptSchema             = $true
    ScriptData               = $false
    NoAssemblies             = $false
    NoCollation              = $true
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
    .DESCRIPTION
        If includeObjectTypes is specified, only those types are exported (whitelist).
        Otherwise, excludeObjectTypes acts as a blacklist.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectType
  )

  # Use script-level $Config variable
  if ($script:Config -and $script:Config.export) {
    # If includeObjectTypes is specified, it acts as a whitelist
    if ($script:Config.export.includeObjectTypes -and $script:Config.export.includeObjectTypes.Count -gt 0) {
      return -not ($script:Config.export.includeObjectTypes -contains $ObjectType)
    }

    # Otherwise, use excludeObjectTypes as a blacklist
    if ($script:Config.export.excludeObjectTypes) {
      return $script:Config.export.excludeObjectTypes -contains $ObjectType
    }
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

function Get-ObjectGroupingMode {
  <#
    .SYNOPSIS
        Gets the file grouping mode for a specific object type.
    .DESCRIPTION
        Returns 'single', 'schema', or 'all' based on configuration.
        Defaults to 'single' if not specified.
    #>
  param(
    [Parameter(Mandatory = $true)]
    [string]$ObjectType
  )

  # Default is 'single' (one file per object)
  $defaultMode = 'single'

  if ($script:Config -and
    $script:Config.export -and
    $script:Config.export.groupByObjectTypes -and
    $script:Config.export.groupByObjectTypes.ContainsKey($ObjectType)) {

    $mode = $script:Config.export.groupByObjectTypes[$ObjectType]
    if ($mode -in @('single', 'schema', 'all')) {
      return $mode
    }
  }

  return $defaultMode
}

#endregion Get-GroupByMode

#region Parallel Export Functions

function New-ExportWorkItem {
  <#
  .SYNOPSIS
      Creates a work item for parallel export processing.
  .DESCRIPTION
      Work items contain object identifiers (not SMO objects) because SMO objects
      are connection-bound and cannot be serialized across runspace boundaries.
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    [string]$ObjectType,

    [Parameter(Mandatory)]
    [string]$GroupingMode,  # 'single', 'schema', 'all'

    [Parameter(Mandatory)]
    [hashtable[]]$Objects,  # Array of @{ Schema = ''; Name = '' }

    [Parameter(Mandatory)]
    [string]$OutputPath,

    [Parameter()]
    [bool]$AppendToFile = $false,

    [Parameter()]
    [hashtable]$ScriptingOptions = @{},

    [Parameter()]
    [string]$SpecialHandler = $null,

    [Parameter()]
    [hashtable]$CustomData = $null
  )

  return @{
    WorkItemId       = [guid]::NewGuid()
    ObjectType       = $ObjectType
    GroupingMode     = $GroupingMode
    Objects          = $Objects
    OutputPath       = $OutputPath
    AppendToFile     = $AppendToFile
    ScriptingOptions = $ScriptingOptions
    SpecialHandler   = $SpecialHandler
    CustomData       = $CustomData
  }
}

function Get-SmoObjectByIdentifier {
  <#
  .SYNOPSIS
      Retrieves an SMO object by its type, schema, and name.
  .DESCRIPTION
      Used by parallel workers to fetch SMO objects from their own database connection.
      Returns $null if object not found (caller should handle).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    $Database,  # Don't type-constrain SMO objects

    [Parameter(Mandatory)]
    [string]$ObjectType,

    [Parameter()]
    [string]$Schema,

    [Parameter(Mandatory)]
    [string]$Name
  )

  try {
    switch ($ObjectType) {
      'Table' { return $Database.Tables[$Name, $Schema] }
      'View' { return $Database.Views[$Name, $Schema] }
      'StoredProcedure' { return $Database.StoredProcedures[$Name, $Schema] }
      'ExtendedStoredProcedure' { return $Database.ExtendedStoredProcedures[$Name, $Schema] }
      'UserDefinedFunction' { return $Database.UserDefinedFunctions[$Name, $Schema] }
      'Schema' { return $Database.Schemas[$Name] }
      'Sequence' { return $Database.Sequences[$Name, $Schema] }
      'Synonym' { return $Database.Synonyms[$Name, $Schema] }
      'UserDefinedType' { return $Database.UserDefinedTypes[$Name, $Schema] }
      'UserDefinedDataType' { return $Database.UserDefinedDataTypes[$Name, $Schema] }
      'UserDefinedTableType' { return $Database.UserDefinedTableTypes[$Name, $Schema] }
      'XmlSchemaCollection' { return $Database.XmlSchemaCollections[$Name, $Schema] }
      'PartitionFunction' { return $Database.PartitionFunctions[$Name] }
      'PartitionScheme' { return $Database.PartitionSchemes[$Name] }
      'Default' { return $Database.Defaults[$Name, $Schema] }
      'Rule' { return $Database.Rules[$Name, $Schema] }
      'DatabaseTrigger' { return $Database.Triggers[$Name] }
      'FullTextCatalog' { return $Database.FullTextCatalogs[$Name] }
      'FullTextStopList' { return $Database.FullTextStopLists[$Name] }
      'SearchPropertyList' { return $Database.SearchPropertyLists[$Name] }
      'SecurityPolicy' { return $Database.SecurityPolicies[$Name, $Schema] }
      'AsymmetricKey' { return $Database.AsymmetricKeys[$Name] }
      'Certificate' { return $Database.Certificates[$Name] }
      'SymmetricKey' { return $Database.SymmetricKeys[$Name] }
      'ApplicationRole' { return $Database.ApplicationRoles[$Name] }
      'DatabaseRole' { return $Database.Roles[$Name] }
      'User' { return $Database.Users[$Name] }
      'PlanGuide' { return $Database.PlanGuides[$Name] }
      'ExternalDataSource' { return $Database.ExternalDataSources[$Name] }
      'ExternalFileFormat' { return $Database.ExternalFileFormats[$Name] }
      'UserDefinedAggregate' { return $Database.UserDefinedAggregates[$Name, $Schema] }
      'SqlAssembly' { return $Database.Assemblies[$Name] }
      'DatabaseAuditSpecification' { return $Database.DatabaseAuditSpecifications[$Name] }
      default {
        Write-Warning "Unknown object type in Get-SmoObjectByIdentifier: $ObjectType"
        return $null
      }
    }
  }
  catch {
    Write-Warning "Failed to get SMO object $Schema.$Name of type $ObjectType : $_"
    return $null
  }
}

function Process-ExportWorkItem {
  <#
  .SYNOPSIS
      Processes a single export work item - shared by both sequential and parallel modes.
  .DESCRIPTION
      This function is the single source of truth for how objects are scripted.
      Both sequential and parallel export modes use this function to ensure
      identical output regardless of export mode.

      The function:
      1. Resolves SMO object(s) from work item identifiers
      2. Configures scripting options
      3. Handles special cases (SecurityPolicy headers, etc.)
      4. Scripts objects to file
  .PARAMETER Database
      The SMO Database object to fetch objects from.
  .PARAMETER Scripter
      The SMO Scripter object for scripting.
  .PARAMETER WorkItem
      The work item containing object identifiers and scripting options.
  .PARAMETER TargetVersion
      The target SQL Server version for script compatibility.
  .OUTPUTS
      Hashtable with Success (bool) and Error (string if failed).
  #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory)]
    $Database,

    [Parameter(Mandatory)]
    $Scripter,

    [Parameter(Mandatory)]
    [hashtable]$WorkItem,

    [Parameter(Mandatory)]
    $TargetVersion
  )

  $result = @{
    WorkItemId = $WorkItem.WorkItemId
    ObjectType = $WorkItem.ObjectType
    OutputPath = $WorkItem.OutputPath
    Success    = $false
    Error      = $null
  }

  try {
    # Ensure output directory exists
    $outputDir = Split-Path $WorkItem.OutputPath -Parent
    if (-not (Test-Path $outputDir)) {
      New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    }

    # Fetch SMO objects by identifier
    $smoObjects = [System.Collections.Generic.List[object]]::new()

    foreach ($objId in $WorkItem.Objects) {
      $smoObj = $null

      # Handle special object types that need custom lookup
      if ($WorkItem.SpecialHandler -eq 'Indexes') {
        # For indexes, fetch the individual index object from the parent table
        $table = $Database.Tables[$objId.TableName, $objId.TableSchema]
        if ($table -and $table.Indexes) {
          $smoObj = $table.Indexes[$objId.IndexName]
        }
      }
      elseif ($WorkItem.SpecialHandler -eq 'ForeignKeys') {
        # For foreign keys, fetch individual FK or parent table depending on grouping mode
        $table = $Database.Tables[$objId.Name, $objId.Schema]
        if ($table -and $objId.FKName -and $WorkItem.GroupingMode -eq 'single') {
          $smoObj = $table.ForeignKeys[$objId.FKName]
        }
        elseif ($table) {
          $smoObj = $table
        }
      }
      elseif ($WorkItem.SpecialHandler -eq 'TableTriggers') {
        # For triggers, fetch individual trigger or parent table depending on grouping mode
        $table = $Database.Tables[$objId.Name, $objId.Schema]
        if ($table -and $objId.TriggerName -and $WorkItem.GroupingMode -eq 'single') {
          $smoObj = $table.Triggers[$objId.TriggerName]
        }
        elseif ($table) {
          $smoObj = $table
        }
      }
      else {
        # Standard object lookup using Get-SmoObjectByIdentifier
        $smoObj = Get-SmoObjectByIdentifier `
          -Database $Database `
          -ObjectType $WorkItem.ObjectType `
          -Schema $objId.Schema `
          -Name $objId.Name
      }

      if ($smoObj) {
        $smoObjects.Add($smoObj)
      }
    }

    if ($smoObjects.Count -eq 0) {
      throw "No SMO objects found for work item"
    }

    # Configure scripting options - these defaults match both modes
    $Scripter.Options = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
    $Scripter.Options.ToFileOnly = $true
    $Scripter.Options.FileName = $WorkItem.OutputPath
    $Scripter.Options.AppendToFile = $WorkItem.AppendToFile
    $Scripter.Options.AnsiFile = $true
    $Scripter.Options.IncludeHeaders = $false    # No date-stamped headers for clean diffs
    $Scripter.Options.NoCollation = $true        # Omit explicit collation for portability
    $Scripter.Options.ScriptBatchTerminator = $true
    $Scripter.Options.TargetServerVersion = $TargetVersion

    # Apply custom scripting options from work item
    foreach ($optKey in $WorkItem.ScriptingOptions.Keys) {
      try {
        $Scripter.Options.$optKey = $WorkItem.ScriptingOptions[$optKey]
      }
      catch {
        # Ignore invalid options
      }
    }

    # Handle special cases that need custom headers or formatting
    if ($WorkItem.SpecialHandler -eq 'SecurityPolicy') {
      # Write custom header first (matches sequential format exactly)
      $policyName = if ($WorkItem.Objects.Count -gt 0) {
        "$($WorkItem.Objects[0].Schema).$($WorkItem.Objects[0].Name)"
      }
      else { "Unknown" }
      $header = "-- Row-Level Security Policy: $policyName`r`n-- NOTE: Ensure predicate functions are created before applying this policy`r`n`r`n"
      [System.IO.File]::WriteAllText($WorkItem.OutputPath, $header, (New-Object System.Text.UTF8Encoding $false))
      $Scripter.Options.AppendToFile = $true
    }

    # Script the objects to file
    $Scripter.EnumScript($smoObjects.ToArray()) | Out-Null

    # Add trailing newline for SecurityPolicy to match sequential format
    if ($WorkItem.SpecialHandler -eq 'SecurityPolicy') {
      [System.IO.File]::AppendAllText($WorkItem.OutputPath, "`r`n", (New-Object System.Text.UTF8Encoding $false))
    }

    $result.Success = $true
  }
  catch {
    $result.Error = $_.Exception.Message
  }

  return $result
}

#endregion Parallel Export Functions

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
    TotalObjects    = 0
    SuccessCount    = 0
    FailCount       = 0
    CategoryTimings = [ordered]@{}
  }

  # OPTIMIZATION: Cache tables collection to avoid duplicate database calls
  # This collection is used by multiple sections: Tables, ForeignKeys, Indexes, TableTriggers, Data
  $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject -and -not (Test-ObjectExcluded -Schema $_.Schema -Name $_.Name) })

  Write-Output ''
  Write-Output '═══════════════════════════════════════════════'
  Write-Output 'EXPORTING DATABASE OBJECTS'
  Write-Output '═══════════════════════════════════════════════'

  #region Parallel Export Branch
  # If parallel mode is enabled, use the parallel export workflow instead of sequential
  if ($script:ParallelEnabled) {
    Write-Host "[INFO] Parallel mode enabled - using parallel export workflow" -ForegroundColor Cyan

    try {
      $parallelSummary = Invoke-ParallelExport `
        -Database $Database `
        -Scripter $Scripter `
        -OutputDir $OutputDir `
        -TargetVersion $TargetVersion

      # Convert parallel summary to metrics format
      $functionMetrics.TotalObjects = $parallelSummary.TotalItems
      $functionMetrics.SuccessCount = $parallelSummary.SuccessCount
      $functionMetrics.FailCount = $parallelSummary.ErrorCount

      return $functionMetrics
    }
    catch {
      Write-Host "[ERROR] Parallel export failed: $_" -ForegroundColor Red
      Write-Host "[INFO] Falling back to sequential export..." -ForegroundColor Yellow
      # Fall through to sequential export below
    }
  }
  #endregion

  # Non-parallelizable objects: FileGroups, DatabaseScopedConfigurations, DatabaseScopedCredentials
  # These use StringBuilder for SQLCMD variable support and require special handling
  Write-Output ''
  Write-Output 'Exporting non-parallelizable objects...'
  Write-ProgressHeader 'FileGroups'
  Write-ProgressHeader 'DatabaseConfiguration'
  $nonParallelResults = Export-NonParallelizableObjects -Database $Database -OutputDir $OutputDir
  if ($nonParallelResults.FileGroups -gt 0) {
    Write-Output "  [SUCCESS] Exported $($nonParallelResults.FileGroups) filegroup(s)"
    Write-Output "  [WARNING] FileGroups contain environment-specific file paths - manual adjustment required"
  }
  else {
    Write-Output "  [INFO] No user-defined filegroups found"
  }
  if ($nonParallelResults.DatabaseScopedConfigurations -gt 0) {
    Write-Output "  [SUCCESS] Exported $($nonParallelResults.DatabaseScopedConfigurations) database scoped configuration(s)"
    Write-Output "  [INFO] Configurations are hardware-specific - review before applying"
  }
  if ($nonParallelResults.DatabaseScopedCredentials -gt 0) {
    Write-Output "  [SUCCESS] Documented $($nonParallelResults.DatabaseScopedCredentials) database scoped credential(s)"
    Write-Output "  [WARNING] Credentials exported as documentation only - secrets must be provided manually"
  }

  #region Sequential Export via Work Items (Hybrid Approach)
  # Build work items using same infrastructure as parallel mode
  # This ensures identical scripting logic regardless of export mode
  Write-Output ''
  Write-Output 'Building work items for export...'
  $allWorkItems = @(Build-ParallelWorkQueue -Database $Database -OutputDir $OutputDir)

  # Filter out TableData items - they are handled separately by Export-TableData
  $workItems = @($allWorkItems | Where-Object { $_.ObjectType -ne 'TableData' })

  if ($workItems.Count -eq 0) {
    Write-Output '  [INFO] No objects to export (all may be excluded by configuration)'
  }
  else {
    Write-Output "  [INFO] Generated $($workItems.Count) work items for export"

    # Define object type display order for consistent output
    $objectTypeOrder = @(
      'Schema', 'Sequence', 'PartitionFunction', 'PartitionScheme',
      'UserDefinedType', 'UserDefinedDataType', 'UserDefinedTableType', 'XmlSchemaCollection',
      'Table', 'ForeignKey', 'Index', 'Default', 'Rule', 'SqlAssembly',
      'UserDefinedFunction', 'UserDefinedAggregate', 'StoredProcedure', 'ExtendedStoredProcedure',
      'DatabaseTrigger', 'TableTrigger', 'View', 'Synonym',
      'FullTextCatalog', 'FullTextStopList', 'ExternalDataSource', 'ExternalFileFormat',
      'SearchPropertyList', 'PlanGuide',
      'AsymmetricKey', 'Certificate', 'SymmetricKey', 'ApplicationRole', 'DatabaseRole', 'User',
      'DatabaseAuditSpecification', 'SecurityPolicy'
    )

    # Group work items by ObjectType
    $groupedItems = $workItems | Group-Object -Property ObjectType

    # Sort groups by defined order (unlisted types go to end)
    $sortedGroups = $groupedItems | Sort-Object {
      $idx = $objectTypeOrder.IndexOf($_.Name)
      if ($idx -lt 0) { 999 } else { $idx }
    }

    foreach ($group in $sortedGroups) {
      $objectType = $group.Name
      $items = @($group.Group)

      # Display friendly name for object type
      $displayName = switch ($objectType) {
        'Schema' { 'Schemas' }
        'Sequence' { 'Sequences' }
        'PartitionFunction' { 'Partition Functions' }
        'PartitionScheme' { 'Partition Schemes' }
        'UserDefinedType' { 'User-Defined Types' }
        'UserDefinedDataType' { 'User-Defined Data Types' }
        'UserDefinedTableType' { 'User-Defined Table Types' }
        'XmlSchemaCollection' { 'XML Schema Collections' }
        'Table' { 'Tables (PKs only)' }
        'ForeignKey' { 'Foreign Keys' }
        'Index' { 'Indexes' }
        'Default' { 'Defaults' }
        'Rule' { 'Rules' }
        'SqlAssembly' { 'Assemblies' }
        'UserDefinedFunction' { 'User-Defined Functions' }
        'UserDefinedAggregate' { 'User-Defined Aggregates' }
        'StoredProcedure' { 'Stored Procedures' }
        'ExtendedStoredProcedure' { 'Extended Stored Procedures' }
        'DatabaseTrigger' { 'Database Triggers' }
        'TableTrigger' { 'Table Triggers' }
        'View' { 'Views' }
        'Synonym' { 'Synonyms' }
        'FullTextCatalog' { 'Full-Text Catalogs' }
        'FullTextStopList' { 'Full-Text Stoplists' }
        'ExternalDataSource' { 'External Data Sources' }
        'ExternalFileFormat' { 'External File Formats' }
        'SearchPropertyList' { 'Search Property Lists' }
        'PlanGuide' { 'Plan Guides' }
        'AsymmetricKey' { 'Asymmetric Keys' }
        'Certificate' { 'Certificates' }
        'SymmetricKey' { 'Symmetric Keys' }
        'ApplicationRole' { 'Application Roles' }
        'DatabaseRole' { 'Database Roles' }
        'User' { 'Users' }
        'DatabaseAuditSpecification' { 'Database Audit Specifications' }
        'SecurityPolicy' { 'Security Policies (Row-Level Security)' }
        default { $objectType }
      }

      Write-Output ''
      Write-Output "Exporting $displayName..."
      Write-Output "  Found $($items.Count) work item(s) to export"
      Write-ProgressHeader $objectType

      $successCount = 0
      $failCount = 0
      $currentItem = 0

      foreach ($workItem in $items) {
        $currentItem++

        # Build object name for progress display
        $objName = if ($workItem.Objects.Count -gt 0) {
          $first = $workItem.Objects[0]
          if ($first.Schema -and $first.Name) {
            "$($first.Schema).$($first.Name)"
          }
          elseif ($first.Name) {
            $first.Name
          }
          elseif ($first.IndexName) {
            # Index work item
            "$($first.TableSchema).$($first.TableName).$($first.IndexName)"
          }
          elseif ($first.FKName) {
            # FK work item
            "$($first.Schema).$($first.Name).$($first.FKName)"
          }
          elseif ($first.TriggerName) {
            # Trigger work item
            "$($first.Schema).$($first.Name).$($first.TriggerName)"
          }
          else {
            "Item $currentItem"
          }
        }
        else {
          "Item $currentItem"
        }

        try {
          Write-ObjectProgress -ObjectName $objName -Current $currentItem -Total $items.Count

          # Process work item using shared function (single source of truth)
          $result = Process-ExportWorkItem `
            -Database $Database `
            -Scripter $Scripter `
            -WorkItem $workItem `
            -TargetVersion $TargetVersion

          if ($result.Success) {
            Write-ObjectProgress -ObjectName $objName -Current $currentItem -Total $items.Count -Success
            $successCount++
            $functionMetrics.SuccessCount++
          }
          else {
            Write-ObjectProgress -ObjectName $objName -Current $currentItem -Total $items.Count -Failed
            Write-Host "  [ERROR] $($result.Error)" -ForegroundColor Red
            $failCount++
            $functionMetrics.FailCount++
          }
          $functionMetrics.TotalObjects++
        }
        catch {
          Write-ObjectProgress -ObjectName $objName -Current $currentItem -Total $items.Count -Failed
          Write-ExportError -ObjectType $objectType -ObjectName $objName -ErrorRecord $_ -FilePath $workItem.OutputPath
          $failCount++
          $functionMetrics.TotalObjects++
          $functionMetrics.FailCount++
        }
      }
      $script:CurrentProgressLabel = $null

      # Summary for this object type
      $summaryMsg = "  [SUMMARY] Exported $successCount/$($items.Count) $displayName successfully"
      if ($failCount -gt 0) {
        $summaryMsg += " ($failCount failed)"
      }
      Write-Output $summaryMsg

      # Special notes for certain object types
      if ($objectType -eq 'SecurityPolicy') {
        Write-Output "  [INFO] Row-Level Security policies require predicate functions to exist first"
      }
    }
  }
  #endregion Sequential Export via Work Items

  # Return metrics summary
  return $functionMetrics
}

function Export-TableData {
  <#
    .SYNOPSIS
        Exports table data as INSERT statements using the unified work items infrastructure.
    .DESCRIPTION
        Routes sequential data export through Build-WorkItems-Data for consistency with parallel mode.
        This ensures both modes use identical logic for row-count filtering and file naming.
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
    SuccessCount   = 0
    FailCount      = 0
    EmptyCount     = 0
    TotalRows      = 0
  }

  Write-Output ''
  Write-Output '═══════════════════════════════════════════════'
  Write-Output 'EXPORTING TABLE DATA'
  Write-Output '═══════════════════════════════════════════════'

  # Use the same work items builder as parallel mode (ensures identical row-count filtering)
  $workItems = @(Build-WorkItems-Data -Database $Database -OutputDir $OutputDir)

  if ($workItems.Count -eq 0) {
    Write-Output '  No tables with data to export.'
    return $dataMetrics
  }

  Write-Output "  Found $($workItems.Count) table(s) with data to export"

  # Configure scripting options for data export
  $opts = New-ScriptingOptions -TargetVersion $TargetVersion -Overrides @{
    ScriptSchema = $false
    ScriptData   = $true
  }

  $successCount = 0
  $failCount = 0

  $currentItem = 0
  Write-ProgressHeader 'TableData'

  foreach ($workItem in $workItems) {
    $currentItem++

    # Get table info from work item
    $objInfo = $workItem.Objects[0]  # Single mode: one table per work item
    $tableName = "$($objInfo.Schema).$($objInfo.Name)"

    try {
      Write-ObjectProgress -ObjectName $tableName -Current $currentItem -Total $workItems.Count

      # Fetch the SMO table object
      $table = $Database.Tables[$objInfo.Name, $objInfo.Schema]
      if (-not $table) {
        throw "Table not found: $tableName"
      }

      # Ensure output directory exists
      Ensure-DirectoryExists $workItem.OutputPath

      # Configure scripter for this file
      $opts.FileName = $workItem.OutputPath
      $opts.AppendToFile = $workItem.AppendToFile
      $Scripter.Options = $opts

      # Script the data
      $Scripter.EnumScript($table) | Out-Null

      Write-ObjectProgress -ObjectName $tableName -Current $currentItem -Total $workItems.Count -Success
      $successCount++
    }
    catch {
      Write-ObjectProgress -ObjectName $tableName -Current $currentItem -Total $workItems.Count -Failed
      Write-ExportError -ObjectType 'TableData' -ObjectName $tableName -ErrorRecord $_
      $failCount++
    }
  }
  $script:CurrentProgressLabel = $null

  Write-Output "  [SUMMARY] Exported data from $successCount/$($workItems.Count) table(s) successfully"
  if ($failCount -gt 0) {
    Write-Output "  [WARNING] Failed to export data from $failCount table(s)"
  }

  # Return metrics summary
  $dataMetrics.TablesWithData = $successCount + $failCount
  $dataMetrics.SuccessCount = $successCount
  $dataMetrics.FailCount = $failCount
  $dataMetrics.EmptyCount = 0  # Empty tables already filtered by Build-WorkItems-Data
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
  [void]$sb.AppendLine("1. 01_Security - Create security objects (keys, certificates, roles, users, audit)")
  [void]$sb.AppendLine("2. 02_DatabaseConfiguration - Apply database scoped configurations (review hardware-specific settings)")
  [void]$sb.AppendLine("3. 03_Schemas - Create database schemas")
  [void]$sb.AppendLine("4. 04_Sequences - Create sequences")
  [void]$sb.AppendLine("5. 05_PartitionFunctions - Create partition functions")
  [void]$sb.AppendLine("6. 06_PartitionSchemes - Create partition schemes")
  [void]$sb.AppendLine("7. 07_Types - Create user-defined types")
  [void]$sb.AppendLine("8. 08_XmlSchemaCollections - Create XML schema collections")
  [void]$sb.AppendLine("9. 09_Tables_PrimaryKey - Create tables with primary keys (no foreign keys)")
  [void]$sb.AppendLine("10. 10_Tables_ForeignKeys - Add foreign key constraints")
  [void]$sb.AppendLine("11. 11_Indexes - Create indexes")
  [void]$sb.AppendLine("12. 12_Defaults - Create default constraints")
  [void]$sb.AppendLine("13. 13_Rules - Create rules")
  [void]$sb.AppendLine("14. 14_Programmability - Create assemblies, functions, procedures, triggers, views (in subfolder order)")
  [void]$sb.AppendLine("15. 15_Synonyms - Create synonyms")
  [void]$sb.AppendLine("16. 16_FullTextSearch - Create full-text search objects")
  [void]$sb.AppendLine("17. 17_ExternalData - Create external data sources and file formats (review connection strings)")
  [void]$sb.AppendLine("18. 18_SearchPropertyLists - Create search property lists")
  [void]$sb.AppendLine("19. 19_PlanGuides - Create plan guides")
  [void]$sb.AppendLine("20. 20_SecurityPolicies - Create Row-Level Security policies (requires schemas and predicate functions)")
  [void]$sb.AppendLine("21. 21_Data - Load data")
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
  $credsPath = Join-Path $OutputDir '02_DatabaseConfiguration' '002_DatabaseScopedCredentials.sql'
  if (Test-Path $credsPath) {
    $credsContent = Get-Content $credsPath -Raw
    if ($credsContent -match 'CREATE DATABASE SCOPED CREDENTIAL') {
      $manualActions += "[ACTION REQUIRED] Database Scoped Credentials"
      $manualActions += "  Location: 02_DatabaseConfiguration\002_DatabaseScopedCredentials.sql"
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
  $dbConfigPath = Join-Path $OutputDir '02_DatabaseConfiguration' '001_DatabaseScopedConfigurations.sql'
  if (Test-Path $dbConfigPath) {
    $manualActions += "[REVIEW RECOMMENDED] Database Scoped Configurations"
    $manualActions += "  Location: 02_DatabaseConfiguration\001_DatabaseScopedConfigurations.sql"
    $manualActions += "  Action: Review MAXDOP and other hardware-specific settings for target server"
  }

  # Check for External Data
  $extDataPath = Join-Path $OutputDir '17_ExternalData'
  if (Test-Path $extDataPath) {
    $extFiles = @(Get-ChildItem -Path $extDataPath -Filter '*.sql' -Recurse)
    if ($extFiles.Count -gt 0) {
      $manualActions += "[ACTION REQUIRED] External Data Sources"
      $manualActions += "  Location: 17_ExternalData\"
      $manualActions += "  Action: Review connection strings and URLs for target environment"
      $manualActions += "  Note: External data sources are environment-specific"
    }
  }

  # Check for Security Policies (RLS)
  $rlsPath = Join-Path $OutputDir '20_SecurityPolicies' '001_SecurityPolicies.sql'
  if (Test-Path $rlsPath) {
    $rlsContent = Get-Content $rlsPath -Raw
    if ($rlsContent -match 'CREATE SECURITY POLICY') {
      $manualActions += "[INFO] Row-Level Security Policies"
      $manualActions += "  Location: 20_SecurityPolicies\001_SecurityPolicies.sql"
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
  }
  else {
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
  $config = @{ export = @{ includeObjectTypes = @(); excludeObjectTypes = @(); includeData = $false; excludeObjects = @() } }
  $configSource = "None (using defaults)"

  if ($ConfigFile) {
    if (Test-Path $ConfigFile) {
      $config = Import-YamlConfig -ConfigFilePath $ConfigFile
      $script:Config = $config  # Store for parallel workers
      $configSource = $ConfigFile

      # Override IncludeData if specified in config
      if ($config.export.includeData -and -not $IncludeData) {
        $IncludeData = $config.export.includeData
        Write-Output "[INFO] Data export enabled from config file"
      }
    }
    else {
      Write-Warning "Config file not found: $ConfigFile"
      Write-Warning "Continuing with default settings..."
    }
  }

  # Store IncludeData in script scope for parallel workers (Build-WorkItems-Data checks this)
  $script:IncludeData = $IncludeData

  # Apply command-line overrides for object type filtering (when no config file or to override config)
  if ($IncludeObjectTypes -and $IncludeObjectTypes.Count -gt 0) {
    $config.export.includeObjectTypes = $IncludeObjectTypes
    Write-Verbose "Command-line override: IncludeObjectTypes = $($IncludeObjectTypes -join ', ')"
  }

  if ($ExcludeObjectTypes -and $ExcludeObjectTypes.Count -gt 0) {
    $config.export.excludeObjectTypes = $ExcludeObjectTypes
    Write-Verbose "Command-line override: ExcludeObjectTypes = $($ExcludeObjectTypes -join ', ')"
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

  # Parallel export settings - Config file first, then command line overrides
  # Start with defaults
  $script:ParallelEnabled = $false
  $script:ParallelMaxWorkers = 5
  $script:ParallelProgressInterval = 50

  # Apply config file settings
  if ($config.export.parallel) {
    if ($config.export.parallel.enabled -eq $true) {
      $script:ParallelEnabled = $true
    }
    elseif ($config.export.parallel.enabled -eq $false) {
      $script:ParallelEnabled = $false
    }
    if ($config.export.parallel.maxWorkers) {
      $script:ParallelMaxWorkers = [Math]::Max(1, [Math]::Min(20, [int]$config.export.parallel.maxWorkers))
    }
    if ($config.export.parallel.progressInterval) {
      $script:ParallelProgressInterval = [Math]::Max(1, [int]$config.export.parallel.progressInterval)
    }
  }

  # Command line switch ALWAYS overrides config file (project rule)
  if ($Parallel.IsPresent) {
    $script:ParallelEnabled = $true
  }

  # Command line -MaxWorkers overrides config file
  if ($MaxWorkers -gt 0) {
    $script:ParallelMaxWorkers = $MaxWorkers
  }

  if ($script:ParallelEnabled) {
    Write-Host "[INFO] Parallel export enabled with $($script:ParallelMaxWorkers) workers" -ForegroundColor Cyan
  }

  # Validate dependencies
  Test-Dependencies

  # Early delta export validation (before connection)
  # Check config file for deltaFrom setting if not specified on command line
  $effectiveDeltaFrom = $DeltaFrom
  if (-not $effectiveDeltaFrom -and $config -and $config.ContainsKey('export')) {
    $exportConfig = $config['export']
    if ($exportConfig -and $exportConfig.ContainsKey('deltaFrom') -and $exportConfig['deltaFrom']) {
      $effectiveDeltaFrom = $exportConfig['deltaFrom']
    }
  }

  if ($effectiveDeltaFrom) {
    Write-Output "Validating delta export from: $effectiveDeltaFrom"

    # Perform early validation that doesn't require database connection
    $deltaValidation = Test-DeltaExportCompatibility `
      -DeltaFromPath $effectiveDeltaFrom `
      -CurrentConfig $config `
      -CurrentServerName $Server `
      -CurrentDatabaseName $Database

    # Show any warnings
    foreach ($warning in $deltaValidation.Warnings) {
      Write-Host "[WARNING] $warning" -ForegroundColor Yellow
    }

    # Check for blocking errors
    if (-not $deltaValidation.IsValid) {
      foreach ($error in $deltaValidation.Errors) {
        Write-Host "[ERROR] $error" -ForegroundColor Red
      }
      throw "Delta export validation failed. See errors above."
    }

    # Store validated delta metadata for later use
    $script:DeltaExportEnabled = $true
    $script:DeltaMetadata = $deltaValidation.Metadata
    $script:DeltaFromPath = $effectiveDeltaFrom
    Write-Output "[SUCCESS] Delta export validated. Previous export: $($script:DeltaMetadata.objectCount) objects from $($script:DeltaMetadata.exportStartTimeServer)"
  }

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
  }
  else {
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

  # Store connection info for parallel workers
  $script:ConnectionInfo = @{
    ServerName             = $Server
    DatabaseName           = $Database
    UseIntegratedSecurity  = ($null -eq $Credential)
    Username               = if ($Credential) { $Credential.UserName } else { $null }
    SecurePassword         = if ($Credential) { $Credential.Password } else { $null }
    TrustServerCertificate = if ($config -and $config.ContainsKey('trustServerCertificate')) { $config.trustServerCertificate } else { $false }
    ConnectTimeout         = $effectiveConnectionTimeout
  }

  Write-Output "[SUCCESS] Connected to $Server\$Database"
  Write-Log "Connected successfully to $Server\$Database" -Severity INFO

  # Initialize export metadata for delta export support
  Initialize-ExportMetadata -Database $smDatabase -ServerName $Server -DatabaseName $Database -IncludeData $IncludeData

  # Log delta export settings if enabled (validation was done earlier before connection)
  if ($script:DeltaExportEnabled) {
    Write-Log "Delta export enabled from $script:DeltaFromPath with $($script:DeltaMetadata.objectCount) objects" -Severity INFO

    # Perform change detection
    $script:DeltaChangeResults = Get-DeltaChangeDetection -Database $smDatabase -PreviousMetadata $script:DeltaMetadata
    Write-Log "Delta change detection: $($script:DeltaChangeResults.ToExport.Count) to export, $($script:DeltaChangeResults.ToCopy.Count) to copy" -Severity INFO

    # Build lookup hashtable for O(1) filtering during export
    Initialize-DeltaExportLookup
  }

  # Record connection time
  if ($connectionTimer) {
    $connectionTimer.Stop()
    $script:Metrics.ConnectionTimeMs = $connectionTimer.ElapsedMilliseconds
  }

  # Configure SMO to prefetch specific properties in bulk when collections are
  # first accessed, eliminating N+1 query problems from lazy loading.
  # We only prefetch properties that don't require VIEW DATABASE STATE privilege.
  Write-Output "Initializing SMO property prefetch..."

  # Prefetch ONLY safe properties that don't require VIEW DATABASE STATE privilege
  # This avoids permission errors while still significantly reducing round-trips
  $prefetchConfig = @{
    [Microsoft.SqlServer.Management.Smo.Table]                = @('Schema', 'Name', 'Owner', 'CreateDate', 'DateLastModified', 'IsSystemObject', 'FileGroup', 'TextFileGroup')
    [Microsoft.SqlServer.Management.Smo.Column]               = @('Name', 'DataType', 'Nullable', 'Identity', 'Computed', 'Default', 'DefaultConstraint')
    [Microsoft.SqlServer.Management.Smo.Index]                = @('Name', 'IndexKeyType', 'IsClustered', 'IsUnique', 'IndexType', 'FileGroup')
    [Microsoft.SqlServer.Management.Smo.ForeignKey]           = @('Name', 'ReferencedTable', 'ReferencedTableSchema', 'IsEnabled', 'IsChecked')
    [Microsoft.SqlServer.Management.Smo.StoredProcedure]      = @('Schema', 'Name', 'Owner', 'CreateDate', 'DateLastModified', 'IsSystemObject', 'IsEncrypted')
    [Microsoft.SqlServer.Management.Smo.View]                 = @('Schema', 'Name', 'Owner', 'CreateDate', 'DateLastModified', 'IsSystemObject', 'IsEncrypted', 'IsIndexed')
    [Microsoft.SqlServer.Management.Smo.UserDefinedFunction]  = @('Schema', 'Name', 'Owner', 'CreateDate', 'DateLastModified', 'IsSystemObject', 'IsEncrypted', 'FunctionType')
    [Microsoft.SqlServer.Management.Smo.Trigger]              = @('Name', 'CreateDate', 'DateLastModified', 'IsSystemObject', 'IsEnabled', 'IsEncrypted')
    [Microsoft.SqlServer.Management.Smo.Schema]               = @('Name', 'Owner', 'ID')
    [Microsoft.SqlServer.Management.Smo.UserDefinedType]      = @('Schema', 'Name', 'Owner', 'CreateDate', 'IsSystemObject')
    [Microsoft.SqlServer.Management.Smo.UserDefinedTableType] = @('Schema', 'Name', 'Owner', 'CreateDate', 'IsSystemObject')
    [Microsoft.SqlServer.Management.Smo.Synonym]              = @('Schema', 'Name', 'Owner', 'CreateDate', 'BaseDatabase', 'BaseSchema', 'BaseObject', 'BaseServer')
    [Microsoft.SqlServer.Management.Smo.Sequence]             = @('Schema', 'Name', 'Owner', 'CreateDate', 'DataType', 'StartValue', 'IncrementValue', 'MinValue', 'MaxValue')
  }

  $prefetchedCount = 0
  foreach ($smoType in $prefetchConfig.Keys) {
    try {
      # First, reset to fetch nothing by default (SetDefaultInitFields with $false)
      $smServer.SetDefaultInitFields($smoType, $false)

      # Then explicitly add only the safe properties we want
      foreach ($propertyName in $prefetchConfig[$smoType]) {
        try {
          $smServer.SetDefaultInitFields($smoType, $propertyName)
        }
        catch {
          # Property may not exist on this SQL Server version - continue
          Write-Verbose "Could not set prefetch for $($smoType.Name).$propertyName"
        }
      }
      $prefetchedCount++
    }
    catch {
      # Type may not be available on all SQL Server versions - continue
      Write-Output "  [INFO] Could not configure prefetch for $($smoType.Name)"
    }
  }

  Write-Output "[SUCCESS] SMO prefetch configured for $prefetchedCount object types (safe properties only)"

  # PrefetchObjects loads entire object collections in bulk upfront (SSMS-style).
  # Does NOT require VIEW DATABASE STATE - loads same metadata, just in bulk.
  Write-Output "Bulk-loading database object metadata..."

  $prefetchTimer = [System.Diagnostics.Stopwatch]::StartNew()
  $prefetchCount = 0

  # Prefetch each major object type individually (single Type parameter overload)
  $typesToPrefetch = @(
    [Microsoft.SqlServer.Management.Smo.Table],
    [Microsoft.SqlServer.Management.Smo.View],
    [Microsoft.SqlServer.Management.Smo.StoredProcedure],
    [Microsoft.SqlServer.Management.Smo.UserDefinedFunction],
    [Microsoft.SqlServer.Management.Smo.Schema],
    [Microsoft.SqlServer.Management.Smo.Synonym]
  )

  foreach ($type in $typesToPrefetch) {
    try {
      $smDatabase.PrefetchObjects($type)
      $prefetchCount++
    }
    catch {
      Write-Verbose "Could not prefetch $($type.Name): $($_.Exception.Message)"
    }
  }

  $prefetchTimer.Stop()
  if ($prefetchCount -gt 0) {
    Write-Output "[SUCCESS] Bulk prefetch completed for $prefetchCount type(s) in $($prefetchTimer.ElapsedMilliseconds)ms"
  }
  else {
    Write-Output "  [INFO] Bulk prefetch not available (using lazy loading with SetDefaultInitFields optimization)"
  }

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
  $scripter.PrefetchObjects = $true  # Enable scripter-level prefetch for dependencies

  # Export schema objects with timing
  $schemaTimer = Start-MetricsTimer -Category 'SchemaExport'
  Write-Output "═══════════════════════════════════════════════════════════════"
  $schemaResult = Export-DatabaseObjects -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
  if ($schemaTimer) {
    $schemaTimer.Stop()
    $script:Metrics.Categories['SchemaExport'] = @{
      DurationMs     = $schemaTimer.ElapsedMilliseconds
      ObjectCount    = if ($schemaResult) { $schemaResult.TotalObjects } else { 0 }
      SuccessCount   = if ($schemaResult) { $schemaResult.SuccessCount } else { 0 }
      FailCount      = if ($schemaResult) { $schemaResult.FailCount } else { 0 }
      AvgMsPerObject = 0
    }
  }

  # Export data if requested with timing (skip if parallel mode - data already exported)
  if ($IncludeData -and -not $script:ParallelEnabled) {
    $dataTimer = Start-MetricsTimer -Category 'DataExport'
    $dataResult = Export-TableData -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion
    if ($dataTimer) {
      $dataTimer.Stop()
      $script:Metrics.Categories['DataExport'] = @{
        DurationMs     = $dataTimer.ElapsedMilliseconds
        ObjectCount    = if ($dataResult) { $dataResult.TablesWithData } else { 0 }
        SuccessCount   = if ($dataResult) { $dataResult.SuccessCount } else { 0 }
        FailCount      = if ($dataResult) { $dataResult.FailCount } else { 0 }
        AvgMsPerObject = 0
      }
    }
  }

  # Save export metadata (required for delta exports)
  Save-ExportMetadata -OutputDir $exportDir

  # Copy unchanged files from previous export if delta mode is active
  if ($script:DeltaExportEnabled -and $script:DeltaChangeResults -and $script:DeltaChangeResults.ToCopy.Count -gt 0) {
    Write-Output ''
    Write-Output 'Copying unchanged objects from previous export...'
    $copyResult = Copy-UnchangedFiles `
      -ToCopyList $script:DeltaChangeResults.ToCopy `
      -SourceExportPath $script:DeltaFromPath `
      -DestinationExportPath $exportDir
    Write-Output "  [SUCCESS] Copied $($copyResult.CopiedCount) unchanged file(s)"
    if ($copyResult.FailedCount -gt 0) {
      Write-Output "  [WARNING] Failed to copy $($copyResult.FailedCount) file(s)"
    }
    Write-Log "Delta export copied $($copyResult.CopiedCount) unchanged files" -Severity INFO
  }

  # Create deployment manifest
  New-DeploymentManifest -OutputDir $exportDir -DatabaseName $Database -ServerName $Server

  # Show export summary
  Show-ExportSummary -OutputDir $exportDir -DatabaseName $Database -ServerName $Server -DataExported $IncludeData

  # Save performance metrics if collection enabled
  Save-PerformanceMetrics -OutputDir $exportDir

  # Check for export failures and exit with error if any occurred
  $totalFailures = 0
  if ($schemaResult -and $schemaResult.FailCount -gt 0) {
    $totalFailures += $schemaResult.FailCount
  }
  if ($dataResult -and $dataResult.FailCount -gt 0) {
    $totalFailures += $dataResult.FailCount
  }

  Write-Output '═══════════════════════════════════════════════'
  Write-Output 'EXPORT COMPLETE'
  Write-Output '═══════════════════════════════════════════════'
  Write-Output ''

  if ($totalFailures -gt 0) {
    Write-Host "[WARNING] Export completed with $totalFailures error(s)" -ForegroundColor Yellow
    Write-Log "Export completed with $totalFailures failures" -Severity WARNING
    exit 1
  }

  Write-Log "Export completed successfully" -Severity INFO

}
catch {
  Write-Error "[ERROR] Script failed: $_"
  Write-Log "Script failed: $_" -Severity ERROR
  exit 1
}
finally {
  # Ensure database connection is closed
  if ($smServer -and $smServer.ConnectionContext.IsOpen) {
    Write-Output 'Disconnecting from SQL Server...'
    $smServer.ConnectionContext.Disconnect()
    Write-Log "Disconnected from SQL Server" -Severity INFO
  }
}

exit 0
