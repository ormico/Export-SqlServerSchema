# Parallel Export - Implementation Guide

**Purpose**: Step-by-step implementation instructions for adding parallel export to Export-SqlServerSchema.ps1  
**Prerequisite**: Read [PARALLEL_EXPORT_DESIGN.md](PARALLEL_EXPORT_DESIGN.md) for architecture overview  
**Target**: AI coding assistants (Sonnet, GPT-4, etc.) and human developers

---

## Quick Reference: Key Files

| File | Purpose |
|------|---------|
| `Export-SqlServerSchema.ps1` | Main script to modify |
| `export-import-config.schema.json` | JSON schema - add parallel config |
| `export-import-config.example.yml` | Example config - add parallel section |
| `tests/run-integration-test.ps1` | Add parallel mode tests |

---

## Implementation Checklist

### Phase 1: Configuration & Parameters

- [ ] **Task 1.1**: Add `-Parallel` switch parameter
- [ ] **Task 1.2**: Add parallel config to JSON schema
- [ ] **Task 1.3**: Add parallel config to example YAML
- [ ] **Task 1.4**: Add config reading logic

### Phase 2: Work Item Infrastructure  

- [ ] **Task 2.1**: Create `New-ExportWorkItem` function
- [ ] **Task 2.2**: Create `Get-SmoObjectByIdentifier` function
- [ ] **Task 2.3**: Create `Build-ParallelWorkQueue` function
- [ ] **Task 2.4**: Create `New-ScriptingOptionsFromHashtable` function

### Phase 3: Worker Implementation

- [ ] **Task 3.1**: Create `Initialize-ParallelRunspacePool` function
- [ ] **Task 3.2**: Define `$script:ParallelWorkerScriptBlock`
- [ ] **Task 3.3**: Create `Start-ParallelWorkers` function
- [ ] **Task 3.4**: Create `Wait-ParallelWorkers` function

### Phase 4: Progress & Results

- [ ] **Task 4.1**: Create `Watch-ParallelProgress` function
- [ ] **Task 4.2**: Create `Get-ParallelResults` function
- [ ] **Task 4.3**: Integrate with existing metrics

### Phase 5: Integration

- [ ] **Task 5.1**: Create `Invoke-ParallelExport` orchestrator function
- [ ] **Task 5.2**: Modify `Export-DatabaseObjects` to branch on parallel mode
- [ ] **Task 5.3**: Handle non-parallelizable objects sequentially first
- [ ] **Task 5.4**: Update deployment manifest generation

### Phase 6: Testing

- [ ] **Task 6.1**: Add parallel integration test
- [ ] **Task 6.2**: Verify sequential mode still works
- [ ] **Task 6.3**: Test all groupBy modes with parallel

---

## Detailed Implementation Tasks

### Task 1.1: Add `-Parallel` Switch Parameter

**File**: `Export-SqlServerSchema.ps1`  
**Location**: Parameter block (around line 50-150)

**Find the existing parameters and add**:
```powershell
[Parameter(HelpMessage = 'Enable parallel export processing for improved performance')]
[switch]$Parallel
```

**Add after other switch parameters like `-IncludeData`**

---

### Task 1.2: Add Parallel Config to JSON Schema

**File**: `export-import-config.schema.json`  
**Location**: Inside `properties.export.properties`

**Add this section**:
```json
"parallel": {
  "type": "object",
  "description": "Parallel export configuration",
  "properties": {
    "enabled": {
      "type": "boolean",
      "default": false,
      "description": "Enable parallel export processing"
    },
    "maxWorkers": {
      "type": "integer",
      "minimum": 1,
      "maximum": 20,
      "default": 5,
      "description": "Maximum number of parallel worker threads"
    },
    "progressInterval": {
      "type": "integer",
      "minimum": 1,
      "default": 50,
      "description": "Report progress every N work items completed"
    }
  },
  "additionalProperties": false
}
```

---

### Task 1.3: Add Parallel Config to Example YAML

**File**: `export-import-config.example.yml`  
**Location**: Under `export:` section

**Add**:
```yaml
  # Parallel export settings (optional)
  parallel:
    enabled: false        # Enable parallel processing (-Parallel switch also enables)
    maxWorkers: 5         # Number of parallel workers (1-20)
    progressInterval: 50  # Report progress every N items
```

---

### Task 1.4: Add Config Reading Logic

**File**: `Export-SqlServerSchema.ps1`  
**Location**: After config file is loaded (search for where `$config` is populated)

**Add after existing config reading**:
```powershell
# Parallel export settings
$parallelEnabled = $Parallel.IsPresent
$parallelMaxWorkers = 5
$parallelProgressInterval = 50

if ($config.export.parallel) {
    if ($config.export.parallel.enabled -eq $true) {
        $parallelEnabled = $true
    }
    if ($config.export.parallel.maxWorkers) {
        $parallelMaxWorkers = [Math]::Max(1, [Math]::Min(20, [int]$config.export.parallel.maxWorkers))
    }
    if ($config.export.parallel.progressInterval) {
        $parallelProgressInterval = [Math]::Max(1, [int]$config.export.parallel.progressInterval)
    }
}

if ($parallelEnabled) {
    Write-Host "[INFO] Parallel export enabled with $parallelMaxWorkers workers" -ForegroundColor Cyan
}
```

---

### Task 2.1: Create `New-ExportWorkItem` Function

**File**: `Export-SqlServerSchema.ps1`  
**Location**: Add in the functions region (before `Export-DatabaseObjects`)

```powershell
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
```

---

### Task 2.2: Create `Get-SmoObjectByIdentifier` Function

**File**: `Export-SqlServerSchema.ps1`  
**Location**: Add after `New-ExportWorkItem`

```powershell
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
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        
        [Parameter(Mandatory)]
        [string]$ObjectType,
        
        [Parameter()]
        [string]$Schema,
        
        [Parameter(Mandatory)]
        [string]$Name
    )
    
    try {
        switch ($ObjectType) {
            'Table'                    { return $Database.Tables[$Name, $Schema] }
            'View'                     { return $Database.Views[$Name, $Schema] }
            'StoredProcedure'          { return $Database.StoredProcedures[$Name, $Schema] }
            'UserDefinedFunction'      { return $Database.UserDefinedFunctions[$Name, $Schema] }
            'Schema'                   { return $Database.Schemas[$Name] }
            'Sequence'                 { return $Database.Sequences[$Name, $Schema] }
            'Synonym'                  { return $Database.Synonyms[$Name, $Schema] }
            'UserDefinedType'          { return $Database.UserDefinedTypes[$Name, $Schema] }
            'UserDefinedDataType'      { return $Database.UserDefinedDataTypes[$Name, $Schema] }
            'UserDefinedTableType'     { return $Database.UserDefinedTableTypes[$Name, $Schema] }
            'XmlSchemaCollection'      { return $Database.XmlSchemaCollections[$Name, $Schema] }
            'PartitionFunction'        { return $Database.PartitionFunctions[$Name] }
            'PartitionScheme'          { return $Database.PartitionSchemes[$Name] }
            'Default'                  { return $Database.Defaults[$Name, $Schema] }
            'Rule'                     { return $Database.Rules[$Name, $Schema] }
            'DatabaseTrigger'          { return $Database.Triggers[$Name] }
            'FullTextCatalog'          { return $Database.FullTextCatalogs[$Name] }
            'FullTextStopList'         { return $Database.FullTextStopLists[$Name] }
            'SearchPropertyList'       { return $Database.SearchPropertyLists[$Name] }
            'SecurityPolicy'           { return $Database.SecurityPolicies[$Name, $Schema] }
            'AsymmetricKey'            { return $Database.AsymmetricKeys[$Name] }
            'Certificate'              { return $Database.Certificates[$Name] }
            'SymmetricKey'             { return $Database.SymmetricKeys[$Name] }
            'ApplicationRole'          { return $Database.ApplicationRoles[$Name] }
            'DatabaseRole'             { return $Database.Roles[$Name] }
            'User'                     { return $Database.Users[$Name] }
            'PlanGuide'                { return $Database.PlanGuides[$Name] }
            'ExternalDataSource'       { return $Database.ExternalDataSources[$Name] }
            'ExternalFileFormat'       { return $Database.ExternalFileFormats[$Name] }
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
```

---

### Task 2.3: Create `Build-ParallelWorkQueue` Function

**File**: `Export-SqlServerSchema.ps1`  
**Location**: Add after `Get-SmoObjectByIdentifier`

This is the most complex function. It mirrors the object enumeration logic in `Export-DatabaseObjects` but creates work items instead of exporting directly.

```powershell
function Build-ParallelWorkQueue {
    <#
    .SYNOPSIS
        Builds the work item queue for parallel export.
    .DESCRIPTION
        Enumerates all exportable objects and creates work items based on grouping mode.
        Does NOT export anything - just builds the queue.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        
        [Parameter(Mandatory)]
        [string]$OutputDir,
        
        [Parameter(Mandatory)]
        [hashtable]$Config,
        
        [Parameter(Mandatory)]
        [string]$TargetVersion,
        
        [Parameter()]
        [string[]]$ObjectTypes = @(),  # Empty = all types
        
        [Parameter()]
        [string[]]$ExcludeObjectTypes = @(),
        
        [Parameter()]
        [bool]$IncludeData = $false
    )
    
    $workItems = [System.Collections.Generic.List[hashtable]]::new()
    
    # Helper to get groupBy mode for an object type
    $getGroupBy = {
        param([string]$TypeName)
        $mode = 'single'  # default
        if ($Config.export.groupBy) {
            if ($Config.export.groupBy -is [string]) {
                $mode = $Config.export.groupBy
            }
            elseif ($Config.export.groupBy.$TypeName) {
                $mode = $Config.export.groupBy.$TypeName
            }
            elseif ($Config.export.groupBy.default) {
                $mode = $Config.export.groupBy.default
            }
        }
        return $mode
    }
    
    # Helper to check if object type should be exported
    $shouldExport = {
        param([string]$TypeName)
        if ($ExcludeObjectTypes -contains $TypeName) { return $false }
        if ($ObjectTypes.Count -eq 0) { return $true }
        return $ObjectTypes -contains $TypeName
    }
    
    #region Tables (09_Tables_PrimaryKey)
    if (& $shouldExport 'Tables') {
        $tables = @($Database.Tables | Where-Object { -not $_.IsSystemObject })
        if ($tables.Count -gt 0) {
            $groupBy = & $getGroupBy 'Tables'
            $baseDir = Join-Path $OutputDir '09_Tables_PrimaryKey'
            
            $scriptOpts = @{
                DriPrimaryKey = $true
                DriForeignKeys = $false
                DriUniqueKeys = $true
                DriChecks = $true
                DriDefaults = $true
                Indexes = $false
                Triggers = $false
            }
            
            switch ($groupBy) {
                'single' {
                    foreach ($table in $tables) {
                        $fileName = "$($table.Schema).$($table.Name).sql"
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'Table' `
                            -GroupingMode 'single' `
                            -Objects @(@{ Schema = $table.Schema; Name = $table.Name }) `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                    }
                }
                'schema' {
                    $bySchema = $tables | Group-Object Schema
                    $schemaNum = 1
                    foreach ($group in $bySchema | Sort-Object Name) {
                        $fileName = "{0:D3}_{1}.sql" -f $schemaNum, $group.Name
                        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'Table' `
                            -GroupingMode 'schema' `
                            -Objects $objects `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                        $schemaNum++
                    }
                }
                'all' {
                    $objects = @($tables | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                    $workItems.Add((New-ExportWorkItem `
                        -ObjectType 'Table' `
                        -GroupingMode 'all' `
                        -Objects $objects `
                        -OutputPath (Join-Path $baseDir '001_Tables.sql') `
                        -ScriptingOptions $scriptOpts))
                }
            }
        }
    }
    #endregion
    
    #region Foreign Keys (10_Tables_ForeignKeys)
    if (& $shouldExport 'ForeignKeys') {
        $fkList = [System.Collections.Generic.List[object]]::new()
        foreach ($table in @($Database.Tables | Where-Object { -not $_.IsSystemObject })) {
            foreach ($fk in $table.ForeignKeys) {
                $fkList.Add(@{
                    TableSchema = $table.Schema
                    TableName = $table.Name
                    FKName = $fk.Name
                })
            }
        }
        
        if ($fkList.Count -gt 0) {
            $groupBy = & $getGroupBy 'ForeignKeys'
            $baseDir = Join-Path $OutputDir '10_Tables_ForeignKeys'
            
            # For FKs, we script the table with FK options only
            $scriptOpts = @{
                DriPrimaryKey = $false
                DriForeignKeys = $true
                DriUniqueKeys = $false
                DriChecks = $false
                DriDefaults = $false
                Indexes = $false
                SchemaQualifyForeignKeysReferences = $true
            }
            
            # Group by parent table for scripting
            switch ($groupBy) {
                'single' {
                    $byTable = $fkList | Group-Object { "$($_.TableSchema).$($_.TableName)" }
                    foreach ($group in $byTable) {
                        $firstFk = $group.Group[0]
                        $fileName = "$($firstFk.TableSchema).$($firstFk.TableName)_ForeignKeys.sql"
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'TableForeignKeys' `
                            -GroupingMode 'single' `
                            -Objects @(@{ Schema = $firstFk.TableSchema; Name = $firstFk.TableName }) `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts `
                            -SpecialHandler 'ForeignKeys'))
                    }
                }
                'schema' {
                    $bySchema = $fkList | Group-Object { $_.TableSchema }
                    $schemaNum = 1
                    foreach ($group in $bySchema | Sort-Object Name) {
                        $fileName = "{0:D3}_{1}_ForeignKeys.sql" -f $schemaNum, $group.Name
                        $tableNames = $group.Group | Select-Object -Property TableSchema, TableName -Unique
                        $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'TableForeignKeys' `
                            -GroupingMode 'schema' `
                            -Objects $objects `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts `
                            -SpecialHandler 'ForeignKeys'))
                        $schemaNum++
                    }
                }
                'all' {
                    $tableNames = $fkList | Select-Object -Property TableSchema, TableName -Unique
                    $objects = @($tableNames | ForEach-Object { @{ Schema = $_.TableSchema; Name = $_.TableName } })
                    $workItems.Add((New-ExportWorkItem `
                        -ObjectType 'TableForeignKeys' `
                        -GroupingMode 'all' `
                        -Objects $objects `
                        -OutputPath (Join-Path $baseDir '001_ForeignKeys.sql') `
                        -ScriptingOptions $scriptOpts `
                        -SpecialHandler 'ForeignKeys'))
                }
            }
        }
    }
    #endregion
    
    #region Views (14_Programmability)
    if (& $shouldExport 'Views') {
        $views = @($Database.Views | Where-Object { -not $_.IsSystemObject })
        if ($views.Count -gt 0) {
            $groupBy = & $getGroupBy 'Views'
            $baseDir = Join-Path $OutputDir '14_Programmability'
            
            $scriptOpts = @{ DriAll = $false }
            
            switch ($groupBy) {
                'single' {
                    foreach ($view in $views) {
                        $fileName = "$($view.Schema).$($view.Name).sql"
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'View' `
                            -GroupingMode 'single' `
                            -Objects @(@{ Schema = $view.Schema; Name = $view.Name }) `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                    }
                }
                'schema' {
                    $bySchema = $views | Group-Object Schema
                    $schemaNum = 1
                    foreach ($group in $bySchema | Sort-Object Name) {
                        $fileName = "{0:D3}_{1}_Views.sql" -f $schemaNum, $group.Name
                        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'View' `
                            -GroupingMode 'schema' `
                            -Objects $objects `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                        $schemaNum++
                    }
                }
                'all' {
                    $objects = @($views | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                    $workItems.Add((New-ExportWorkItem `
                        -ObjectType 'View' `
                        -GroupingMode 'all' `
                        -Objects $objects `
                        -OutputPath (Join-Path $baseDir '001_Views.sql') `
                        -ScriptingOptions $scriptOpts))
                }
            }
        }
    }
    #endregion
    
    #region StoredProcedures (14_Programmability)
    if (& $shouldExport 'StoredProcedures') {
        $procs = @($Database.StoredProcedures | Where-Object { -not $_.IsSystemObject })
        if ($procs.Count -gt 0) {
            $groupBy = & $getGroupBy 'StoredProcedures'
            $baseDir = Join-Path $OutputDir '14_Programmability'
            
            $scriptOpts = @{}
            
            switch ($groupBy) {
                'single' {
                    foreach ($proc in $procs) {
                        $fileName = "$($proc.Schema).$($proc.Name).sql"
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'StoredProcedure' `
                            -GroupingMode 'single' `
                            -Objects @(@{ Schema = $proc.Schema; Name = $proc.Name }) `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                    }
                }
                'schema' {
                    $bySchema = $procs | Group-Object Schema
                    $schemaNum = 1
                    foreach ($group in $bySchema | Sort-Object Name) {
                        $fileName = "{0:D3}_{1}_StoredProcedures.sql" -f $schemaNum, $group.Name
                        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'StoredProcedure' `
                            -GroupingMode 'schema' `
                            -Objects $objects `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                        $schemaNum++
                    }
                }
                'all' {
                    $objects = @($procs | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                    $workItems.Add((New-ExportWorkItem `
                        -ObjectType 'StoredProcedure' `
                        -GroupingMode 'all' `
                        -Objects $objects `
                        -OutputPath (Join-Path $baseDir '001_StoredProcedures.sql') `
                        -ScriptingOptions $scriptOpts))
                }
            }
        }
    }
    #endregion
    
    #region UserDefinedFunctions (14_Programmability)
    if (& $shouldExport 'Functions') {
        $funcs = @($Database.UserDefinedFunctions | Where-Object { -not $_.IsSystemObject })
        if ($funcs.Count -gt 0) {
            $groupBy = & $getGroupBy 'Functions'
            $baseDir = Join-Path $OutputDir '14_Programmability'
            
            $scriptOpts = @{}
            
            switch ($groupBy) {
                'single' {
                    foreach ($func in $funcs) {
                        $fileName = "$($func.Schema).$($func.Name).sql"
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'UserDefinedFunction' `
                            -GroupingMode 'single' `
                            -Objects @(@{ Schema = $func.Schema; Name = $func.Name }) `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                    }
                }
                'schema' {
                    $bySchema = $funcs | Group-Object Schema
                    $schemaNum = 1
                    foreach ($group in $bySchema | Sort-Object Name) {
                        $fileName = "{0:D3}_{1}_Functions.sql" -f $schemaNum, $group.Name
                        $objects = @($group.Group | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                        $workItems.Add((New-ExportWorkItem `
                            -ObjectType 'UserDefinedFunction' `
                            -GroupingMode 'schema' `
                            -Objects $objects `
                            -OutputPath (Join-Path $baseDir $fileName) `
                            -ScriptingOptions $scriptOpts))
                        $schemaNum++
                    }
                }
                'all' {
                    $objects = @($funcs | ForEach-Object { @{ Schema = $_.Schema; Name = $_.Name } })
                    $workItems.Add((New-ExportWorkItem `
                        -ObjectType 'UserDefinedFunction' `
                        -GroupingMode 'all' `
                        -Objects $objects `
                        -OutputPath (Join-Path $baseDir '001_Functions.sql') `
                        -ScriptingOptions $scriptOpts))
                }
            }
        }
    }
    #endregion
    
    # NOTE: Continue this pattern for all other parallelizable object types:
    # - Schemas (03_Schemas)
    # - Sequences (04_Sequences)
    # - PartitionFunctions (05_PartitionFunctions)
    # - PartitionSchemes (06_PartitionSchemes)
    # - Types - UserDefinedTypes, UserDefinedDataTypes, UserDefinedTableTypes (07_Types)
    # - XmlSchemaCollections (08_XmlSchemaCollections)
    # - Indexes (11_Indexes) - nested from tables
    # - Defaults (12_Defaults)
    # - Rules (13_Rules)
    # - Triggers - both database and table triggers (14_Programmability)
    # - Synonyms (15_Synonyms)
    # - FullTextCatalogs, FullTextStopLists (16_FullTextSearch)
    # - ExternalDataSources, ExternalFileFormats (17_ExternalData)
    # - SearchPropertyLists (18_SearchPropertyLists)
    # - PlanGuides (19_PlanGuides)
    # - SecurityPolicies (20_SecurityPolicies)
    # - Security objects: Certificates, AsymmetricKeys, SymmetricKeys, Roles, Users (01_Security)
    # - Data export if IncludeData (21_Data)
    
    return $workItems
}
```

**IMPORTANT**: The above is a starter implementation. You must expand it to cover ALL object types listed in the design document. Follow the existing patterns in `Export-DatabaseObjects` for each object type.

---

### Task 2.4: Create `New-ScriptingOptionsFromHashtable` Function

```powershell
function New-ScriptingOptionsFromHashtable {
    <#
    .SYNOPSIS
        Creates SMO ScriptingOptions from a hashtable of settings.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.SqlServer.Management.Smo.Server]$Server,
        
        [Parameter()]
        [hashtable]$Options = @{}
    )
    
    $scriptOpts = [Microsoft.SqlServer.Management.Smo.ScriptingOptions]::new()
    
    # Apply each option from hashtable
    foreach ($key in $Options.Keys) {
        try {
            $scriptOpts.$key = $Options[$key]
        }
        catch {
            Write-Warning "Invalid scripting option: $key"
        }
    }
    
    return $scriptOpts
}
```

---

### Task 3.1: Create `Initialize-ParallelRunspacePool` Function

```powershell
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
```

---

### Task 3.2: Define Worker Script Block

**Add as script-scoped variable near top of script**:

```powershell
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
        $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ConnectionInfo.ServerName)
        
        if ($ConnectionInfo.UseIntegratedSecurity) {
            $server.ConnectionContext.LoginSecure = $true
        }
        else {
            $server.ConnectionContext.LoginSecure = $false
            $server.ConnectionContext.Login = $ConnectionInfo.Username
            $server.ConnectionContext.SecurePassword = $ConnectionInfo.SecurePassword
        }
        
        if ($ConnectionInfo.TrustServerCertificate) {
            $server.ConnectionContext.TrustServerCertificate = $true
        }
        
        $server.ConnectionContext.ConnectTimeout = 30
        $server.ConnectionContext.Connect()
        
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
            WorkItemId = [guid]::Empty
            Success = $false
            ObjectCount = 0
            Error = "Worker setup failed: $($_.Exception.Message)"
            ObjectType = 'WorkerSetup'
            Objects = @()
        })
        return
    }
    #endregion
    
    #region Work Loop
    $workItem = $null
    while ($WorkQueue.TryDequeue([ref]$workItem)) {
        $result = @{
            WorkItemId  = $workItem.WorkItemId
            Success     = $false
            ObjectCount = $workItem.Objects.Count
            Error       = $null
            ObjectType  = $workItem.ObjectType
            Objects     = $workItem.Objects
        }
        
        try {
            # Ensure output directory exists
            $outputDir = Split-Path -Parent $workItem.OutputPath
            if (-not (Test-Path $outputDir)) {
                New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
            }
            
            # Fetch SMO objects by identifier
            $smoObjects = [System.Collections.Generic.List[object]]::new()
            
            foreach ($objId in $workItem.Objects) {
                $smoObj = $null
                
                # Handle special object types
                if ($workItem.SpecialHandler -eq 'ForeignKeys') {
                    # For FKs, we need the table, then script with FK options
                    $smoObj = $db.Tables[$objId.Name, $objId.Schema]
                }
                else {
                    # Standard object lookup
                    switch ($workItem.ObjectType) {
                        'Table'                    { $smoObj = $db.Tables[$objId.Name, $objId.Schema] }
                        'View'                     { $smoObj = $db.Views[$objId.Name, $objId.Schema] }
                        'StoredProcedure'          { $smoObj = $db.StoredProcedures[$objId.Name, $objId.Schema] }
                        'UserDefinedFunction'      { $smoObj = $db.UserDefinedFunctions[$objId.Name, $objId.Schema] }
                        'Schema'                   { $smoObj = $db.Schemas[$objId.Name] }
                        'Sequence'                 { $smoObj = $db.Sequences[$objId.Name, $objId.Schema] }
                        'Synonym'                  { $smoObj = $db.Synonyms[$objId.Name, $objId.Schema] }
                        'UserDefinedType'          { $smoObj = $db.UserDefinedTypes[$objId.Name, $objId.Schema] }
                        'UserDefinedDataType'      { $smoObj = $db.UserDefinedDataTypes[$objId.Name, $objId.Schema] }
                        'UserDefinedTableType'     { $smoObj = $db.UserDefinedTableTypes[$objId.Name, $objId.Schema] }
                        'XmlSchemaCollection'      { $smoObj = $db.XmlSchemaCollections[$objId.Name, $objId.Schema] }
                        'PartitionFunction'        { $smoObj = $db.PartitionFunctions[$objId.Name] }
                        'PartitionScheme'          { $smoObj = $db.PartitionSchemes[$objId.Name] }
                        'Default'                  { $smoObj = $db.Defaults[$objId.Name, $objId.Schema] }
                        'Rule'                     { $smoObj = $db.Rules[$objId.Name, $objId.Schema] }
                        'DatabaseTrigger'          { $smoObj = $db.Triggers[$objId.Name] }
                        'FullTextCatalog'          { $smoObj = $db.FullTextCatalogs[$objId.Name] }
                        'FullTextStopList'         { $smoObj = $db.FullTextStopLists[$objId.Name] }
                        'SearchPropertyList'       { $smoObj = $db.SearchPropertyLists[$objId.Name] }
                        'SecurityPolicy'           { $smoObj = $db.SecurityPolicies[$objId.Name, $objId.Schema] }
                        'AsymmetricKey'            { $smoObj = $db.AsymmetricKeys[$objId.Name] }
                        'Certificate'              { $smoObj = $db.Certificates[$objId.Name] }
                        'SymmetricKey'             { $smoObj = $db.SymmetricKeys[$objId.Name] }
                        'ApplicationRole'          { $smoObj = $db.ApplicationRoles[$objId.Name] }
                        'DatabaseRole'             { $smoObj = $db.Roles[$objId.Name] }
                        'User'                     { $smoObj = $db.Users[$objId.Name] }
                        'PlanGuide'                { $smoObj = $db.PlanGuides[$objId.Name] }
                        'ExternalDataSource'       { $smoObj = $db.ExternalDataSources[$objId.Name] }
                        'ExternalFileFormat'       { $smoObj = $db.ExternalFileFormats[$objId.Name] }
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
            $scripter.Options.IncludeHeaders = $true
            $scripter.Options.ScriptBatchTerminator = $true
            
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
                # Write custom header first
                $header = "-- Row-Level Security Policy`r`n-- NOTE: Ensure predicate functions exist before running`r`nGO`r`n"
                [System.IO.File]::WriteAllText($workItem.OutputPath, $header, [System.Text.Encoding]::UTF8)
                $scripter.Options.AppendToFile = $true
            }
            
            # Script the objects
            $scripter.EnumScript($smoObjects.ToArray()) | Out-Null
            
            $result.Success = $true
        }
        catch {
            $result.Error = $_.Exception.Message
        }
        
        # Record result
        $ResultsBag.Add($result)
        
        # Increment progress (atomic)
        [System.Threading.Interlocked]::Increment($ProgressCounter)
    }
    #endregion
    
    #region Cleanup
    try {
        if ($server -and $server.ConnectionContext.IsOpen) {
            $server.ConnectionContext.Disconnect()
        }
    }
    catch {
        # Ignore cleanup errors
    }
    #endregion
}
```

---

### Task 3.3: Create `Start-ParallelWorkers` Function

```powershell
function Start-ParallelWorkers {
    <#
    .SYNOPSIS
        Starts parallel workers in the runspace pool.
    .OUTPUTS
        Array of worker objects with PowerShell and Handle properties.
    #>
    [CmdletBinding()]
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
    
    return $workers
}
```

---

### Task 3.4: Create `Wait-ParallelWorkers` Function

```powershell
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
```

---

### Task 5.1: Create `Invoke-ParallelExport` Orchestrator Function

```powershell
function Invoke-ParallelExport {
    <#
    .SYNOPSIS
        Orchestrates parallel export of database objects.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [Microsoft.SqlServer.Management.Smo.Database]$Database,
        
        [Parameter(Mandatory)]
        [string]$OutputDir,
        
        [Parameter(Mandatory)]
        [Microsoft.SqlServer.Management.Smo.Scripter]$Scripter,
        
        [Parameter(Mandatory)]
        [hashtable]$Config,
        
        [Parameter(Mandatory)]
        [string]$TargetVersion,
        
        [Parameter(Mandatory)]
        [int]$MaxWorkers,
        
        [Parameter()]
        [int]$ProgressInterval = 50,
        
        [Parameter()]
        [string[]]$ObjectTypes = @(),
        
        [Parameter()]
        [string[]]$ExcludeObjectTypes = @(),
        
        [Parameter()]
        [bool]$IncludeData = $false,
        
        [Parameter(Mandatory)]
        [hashtable]$ConnectionInfo
    )
    
    Write-Host ""
    Write-ProgressHeader "Parallel Export"
    
    #region Phase 1: Handle Non-Parallelizable Objects Sequentially
    Write-Host "[Parallel] Exporting non-parallelizable objects sequentially..." -ForegroundColor Cyan
    
    # FileGroups, DatabaseScopedConfigurations, DatabaseScopedCredentials
    # These use custom logic - call existing export functions here
    # Example: Export-FileGroups -Database $Database -OutputDir $OutputDir -Config $Config
    
    #endregion
    
    #region Phase 2: Build Work Queue
    Write-Host "[Parallel] Building work queue..." -ForegroundColor Cyan
    
    $workItems = Build-ParallelWorkQueue `
        -Database $Database `
        -OutputDir $OutputDir `
        -Config $Config `
        -TargetVersion $TargetVersion `
        -ObjectTypes $ObjectTypes `
        -ExcludeObjectTypes $ExcludeObjectTypes `
        -IncludeData $IncludeData
    
    if ($workItems.Count -eq 0) {
        Write-Host "[Parallel] No work items to process" -ForegroundColor Yellow
        return @{
            TotalObjects = 0
            SuccessCount = 0
            FailCount = 0
        }
    }
    
    Write-Host "[Parallel] Queued $($workItems.Count) work items" -ForegroundColor Cyan
    
    # Create concurrent queue
    $workQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
    foreach ($item in $workItems) {
        $workQueue.Enqueue($item)
    }
    
    # Create shared state
    $progressCounter = [ref][int]0
    $resultsBag = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
    
    #endregion
    
    #region Phase 3: Start Workers
    Write-Host "[Parallel] Starting $MaxWorkers workers..." -ForegroundColor Cyan
    
    $runspacePool = Initialize-ParallelRunspacePool -MaxWorkers $MaxWorkers
    
    try {
        $workers = Start-ParallelWorkers `
            -RunspacePool $runspacePool `
            -WorkerCount $MaxWorkers `
            -WorkQueue $workQueue `
            -ProgressCounter $progressCounter `
            -ResultsBag $resultsBag `
            -ConnectionInfo $ConnectionInfo `
            -TargetVersion $TargetVersion
        
        # Wait for completion with progress
        Wait-ParallelWorkers `
            -Workers $workers `
            -ProgressCounter $progressCounter `
            -TotalItems $workItems.Count `
            -ProgressInterval $ProgressInterval
    }
    finally {
        $runspacePool.Close()
        $runspacePool.Dispose()
    }
    
    #endregion
    
    #region Phase 4: Aggregate Results
    $results = @($resultsBag.ToArray())
    $successes = @($results | Where-Object { $_.Success })
    $failures = @($results | Where-Object { -not $_.Success })
    
    $totalObjects = ($results | Measure-Object -Property ObjectCount -Sum).Sum
    
    Write-Host ""
    Write-Host "[Parallel] Success: $($successes.Count) work items, Failed: $($failures.Count)" -ForegroundColor $(if ($failures.Count -eq 0) { 'Green' } else { 'Yellow' })
    
    if ($failures.Count -gt 0) {
        Write-Host ""
        Write-Host "FAILED ITEMS:" -ForegroundColor Red
        foreach ($failure in $failures) {
            $objNames = ($failure.Objects | ForEach-Object { "$($_.Schema).$($_.Name)" }) -join ', '
            Write-Host "  [ERROR] $($failure.ObjectType) $objNames" -ForegroundColor Yellow -NoNewline
            Write-Host ": $($failure.Error)" -ForegroundColor Red
        }
    }
    
    #endregion
    
    return @{
        TotalObjects = $totalObjects
        SuccessCount = $successes.Count
        FailCount = $failures.Count
        Failures = $failures
    }
}
```

---

### Task 5.2: Modify `Export-DatabaseObjects` to Branch

**Location**: Inside `Export-DatabaseObjects` function, near the beginning

**Add this check**:
```powershell
# Check if parallel mode is enabled
if ($script:ParallelEnabled) {
    return Invoke-ParallelExport `
        -Database $Database `
        -OutputDir $OutputDir `
        -Scripter $Scripter `
        -Config $script:Config `
        -TargetVersion $TargetVersion `
        -MaxWorkers $script:ParallelMaxWorkers `
        -ProgressInterval $script:ParallelProgressInterval `
        -ObjectTypes $ObjectTypes `
        -ExcludeObjectTypes $ExcludeObjectTypes `
        -IncludeData $IncludeData `
        -ConnectionInfo $script:ConnectionInfo
}

# ... existing sequential export code continues ...
```

---

## Testing

### Integration Test Addition

**File**: `tests/run-integration-test.ps1`

Add a parallel mode test:

```powershell
# Test parallel export
Write-Host "`n=== Testing Parallel Export ===" -ForegroundColor Cyan

$parallelExportDir = Join-Path $testExportsDir "parallel_test"
& "$PSScriptRoot\..\Export-SqlServerSchema.ps1" `
    -Server $server `
    -Database $testDbName `
    -OutputPath $parallelExportDir `
    -Parallel `
    -Credential $cred

if ($LASTEXITCODE -ne 0) {
    Write-Host "[FAIL] Parallel export failed" -ForegroundColor Red
    exit 1
}

# Verify output matches sequential export
$seqFiles = Get-ChildItem $exportDir -Recurse -File | Sort-Object FullName
$parFiles = Get-ChildItem $parallelExportDir -Recurse -File | Sort-Object FullName

if ($seqFiles.Count -ne $parFiles.Count) {
    Write-Host "[FAIL] Parallel export file count mismatch: seq=$($seqFiles.Count), par=$($parFiles.Count)" -ForegroundColor Red
}
else {
    Write-Host "[PASS] Parallel export produced same number of files" -ForegroundColor Green
}
```

---

## Common Pitfalls to Avoid

1. **Don't pass SMO objects across runspaces** - They're connection-bound. Pass identifiers only.

2. **Don't forget to dispose runspace pool** - Use try/finally to ensure cleanup.

3. **Don't use Write-Output in workers** - Output is captured. Use ResultsBag for communication.

4. **Don't forget to import SqlServer module in runspaces** - Workers need their own module load.

5. **Don't assume all object types have Schema** - Some (PartitionFunction, FullTextCatalog) don't.

6. **Handle empty collections** - Check `.Count` before processing.

7. **Test with all groupBy modes** - single, schema, all each have different work item patterns.

---

## Verification Checklist

Before considering implementation complete:

- [ ] `-Parallel` switch works from command line
- [ ] `export.parallel.enabled: true` in YAML works
- [ ] Sequential mode still works (no regression)
- [ ] All object types export correctly in parallel
- [ ] Progress display shows accurate counts
- [ ] Errors are collected and reported
- [ ] File output matches sequential mode
- [ ] Works with groupBy: single
- [ ] Works with groupBy: schema  
- [ ] Works with groupBy: all
- [ ] Works with data export
- [ ] Integration tests pass
