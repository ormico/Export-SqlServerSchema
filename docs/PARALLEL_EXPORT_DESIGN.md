# Parallel Export Feature - Design Document

**Version**: 1.0  
**Date**: January 22, 2026  
**Status**: Approved for Implementation

---

## Executive Summary

Add optional parallel processing to `Export-SqlServerSchema.ps1` to leverage multiple CPU cores during script generation. This feature is opt-in via the `-Parallel` switch and aims to reduce export time for large databases.

---

## Goals

1. **Performance**: Reduce export time by parallelizing script generation
2. **Stability**: No regression in sequential mode; parallel mode must be equally reliable
3. **Simplicity**: Minimal user-facing complexity; sensible defaults
4. **Compatibility**: Works with existing groupBy settings (single/schema/all)

## Non-Goals (v1)

- Splitting large work items into chunks
- Dynamic worker scaling based on queue depth
- Progress per object type (aggregated progress only)

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PHASE 1: ENUMERATION                                │
│                         (Sequential, Main Thread)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Connect to database (main connection)                                   │
│  2. Prefetch all collections with PrefetchObjects = $true                   │
│  3. Handle NON-PARALLELIZABLE object types sequentially:                    │
│     ┌─────────────────────────────────────────────────────────────────┐     │
│     │ • FileGroups (custom string builder, SQLCMD variables)          │     │
│     │ • DatabaseScopedConfigurations (not SMO scriptable)             │     │
│     │ • DatabaseScopedCredentials (documentation only, no secrets)    │     │
│     └─────────────────────────────────────────────────────────────────┘     │
│  4. For each PARALLELIZABLE object type:                                    │
│     • Determine grouping mode (single/schema/all) from config               │
│     • Create work items with IDENTIFIERS (not SMO objects)                  │
│     • Add to ConcurrentQueue<WorkItem>                                      │
│  5. Pre-create all output directories                                       │
│  6. Record total work item count for progress tracking                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PHASE 2: PARALLEL SCRIPTING                         │
│                         (N Worker Runspaces)                                │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌───────────────┐ ┌───────────────┐ ┌───────────────┐ ┌───────────────┐   │
│  │   Worker 1    │ │   Worker 2    │ │   Worker 3    │ │   Worker N    │   │
│  │               │ │               │ │               │ │               │   │
│  │ • Own SMO     │ │ • Own SMO     │ │ • Own SMO     │ │ • Own SMO     │   │
│  │   Connection  │ │   Connection  │ │   Connection  │ │   Connection  │   │
│  │ • Own         │ │ • Own         │ │ • Own         │ │ • Own         │   │
│  │   Scripter    │ │   Scripter    │ │   Scripter    │ │   Scripter    │   │
│  │ • Prefetch    │ │ • Prefetch    │ │ • Prefetch    │ │ • Prefetch    │   │
│  │   Enabled     │ │   Enabled     │ │   Enabled     │ │   Enabled     │   │
│  └───────┬───────┘ └───────┬───────┘ └───────┬───────┘ └───────┬───────┘   │
│          │                 │                 │                 │           │
│          └─────────────────┴────────┬────────┴─────────────────┘           │
│                                     │                                       │
│                                     ▼                                       │
│                    ┌────────────────────────────────┐                       │
│                    │  ConcurrentQueue<WorkItem>     │                       │
│                    │  (Thread-Safe, Lock-Free)      │                       │
│                    └────────────────────────────────┘                       │
│                                     │                                       │
│                    ┌────────────────┼────────────────┐                      │
│                    ▼                ▼                ▼                      │
│           ┌──────────────┐ ┌──────────────┐ ┌──────────────┐               │
│           │   Progress   │ │   Results    │ │   Errors     │               │
│           │   Counter    │ │     Bag      │ │     Bag      │               │
│           │  (Atomic)    │ │ (Concurrent) │ │ (Concurrent) │               │
│           └──────────────┘ └──────────────┘ └──────────────┘               │
│                                                                             │
│  Main Thread: Poll progress counter every 500ms, display progress           │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                         PHASE 3: AGGREGATION                                │
│                         (Sequential, Main Thread)                           │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  1. Wait for all workers to complete (runspace pool close)                  │
│  2. Aggregate metrics from Results Bag (totals only)                        │
│  3. Collect and report all errors from Errors Bag                           │
│  4. Generate deployment manifest (_DEPLOYMENT_README.md)                    │
│  5. Display summary                                                         │
│  6. Set exit code based on error count                                      │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

---

## Data Structures

### WorkItem

Work items contain **identifiers only** (not SMO objects) because SMO objects are connection-bound and cannot be serialized across runspace boundaries.

```powershell
class WorkItem {
    [guid]$WorkItemId
    [string]$ObjectType          # Table, View, StoredProcedure, etc.
    [string]$GroupingMode        # single, schema, all
    [hashtable[]]$Objects        # Array of @{ Schema = ''; Name = '' }
    [string]$OutputPath          # Full path to output file
    [bool]$AppendToFile          # First object in file = $false, rest = $true
    [hashtable]$ScriptingOptions # Serializable options (not SMO ScriptingOptions)
    [string]$SpecialHandler      # null or 'SecurityPolicy', etc.
    [hashtable]$CustomData       # Handler-specific data
}
```

**Example Work Items by Grouping Mode:**

```powershell
# GroupBy: single - one work item per object
@{
    WorkItemId = [guid]::NewGuid()
    ObjectType = 'Table'
    GroupingMode = 'single'
    Objects = @( @{ Schema = 'dbo'; Name = 'Customers' } )
    OutputPath = 'D:\export\09_Tables_PrimaryKey\dbo.Customers.sql'
    AppendToFile = $false
    ScriptingOptions = @{ DriPrimaryKey = $true; DriForeignKeys = $false }
}

# GroupBy: schema - one work item per schema
@{
    WorkItemId = [guid]::NewGuid()
    ObjectType = 'Table'
    GroupingMode = 'schema'
    Objects = @(
        @{ Schema = 'dbo'; Name = 'Customers' },
        @{ Schema = 'dbo'; Name = 'Orders' },
        @{ Schema = 'dbo'; Name = 'Products' }
    )
    OutputPath = 'D:\export\09_Tables_PrimaryKey\001_dbo.sql'
    AppendToFile = $false  # First object; scripter handles append internally
    ScriptingOptions = @{ DriPrimaryKey = $true; DriForeignKeys = $false }
}

# GroupBy: all - one work item for all objects of type
@{
    WorkItemId = [guid]::NewGuid()
    ObjectType = 'Table'
    GroupingMode = 'all'
    Objects = @(
        @{ Schema = 'dbo'; Name = 'Customers' },
        @{ Schema = 'dbo'; Name = 'Orders' },
        @{ Schema = 'Sales'; Name = 'Invoices' }
        # ... all tables ...
    )
    OutputPath = 'D:\export\09_Tables_PrimaryKey\001_AllTables.sql'
    AppendToFile = $false
    ScriptingOptions = @{ DriPrimaryKey = $true; DriForeignKeys = $false }
}
```

### WorkerResult

```powershell
@{
    WorkItemId   = [guid]       # Correlation to work item
    Success      = [bool]       # $true or $false
    ObjectCount  = [int]        # Number of objects in work item
    Error        = [string]     # Error message if failed (null if success)
    ObjectType   = [string]     # For error reporting
    Objects      = [hashtable[]]# For error reporting
}
```

### Thread-Safe Collections

```powershell
# Work queue (main → workers)
$workQueue = [System.Collections.Concurrent.ConcurrentQueue[hashtable]]::new()

# Progress counter (workers → main)
$progressCounter = [ref][int]0  # Used with [Interlocked]::Increment

# Results collection (workers → main)
$resultsBag = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
```

---

## Configuration

### Command-Line Parameters

```powershell
[Parameter(HelpMessage = 'Enable parallel export processing')]
[switch]$Parallel

# Note: Detailed parallel settings come from config file
```

### YAML Configuration

```yaml
export:
  parallel:
    enabled: true           # Can also be enabled via -Parallel switch
    maxWorkers: 5           # Default: 5, valid range: 1-20
    progressInterval: 50    # Display progress every N work items completed
```

### Schema Update (export-import-config.schema.json)

```json
{
  "export": {
    "type": "object",
    "properties": {
      "parallel": {
        "type": "object",
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
            "description": "Maximum number of parallel workers"
          },
          "progressInterval": {
            "type": "integer",
            "minimum": 1,
            "default": 50,
            "description": "Report progress every N items"
          }
        }
      }
    }
  }
}
```

---

## Object Type Classification

### Non-Parallelizable (Run Sequentially First)

These object types use custom scripting logic that doesn't fit the standard SMO Scripter pattern:

| Object Type | Reason |
|-------------|--------|
| FileGroups | Custom StringBuilder, SQLCMD variable injection, cross-platform paths |
| DatabaseScopedConfigurations | Direct property access, not SMO Scripter compatible |
| DatabaseScopedCredentials | Documentation-only export (secrets cannot be scripted) |

### Parallelizable (Standard SMO Scripting)

| Object Type | SMO Collection | Notes |
|-------------|----------------|-------|
| Schemas | `$db.Schemas` | |
| Sequences | `$db.Sequences` | |
| PartitionFunctions | `$db.PartitionFunctions` | |
| PartitionSchemes | `$db.PartitionSchemes` | |
| Types | `$db.UserDefinedTypes`, `$db.UserDefinedDataTypes`, `$db.UserDefinedTableTypes` | Multiple collections |
| XmlSchemaCollections | `$db.XmlSchemaCollections` | |
| Tables | `$db.Tables` | With PK options |
| ForeignKeys | `$table.ForeignKeys` | Nested collection |
| Indexes | `$table.Indexes` | Nested collection |
| Defaults | `$db.Defaults` | |
| Rules | `$db.Rules` | |
| Functions | `$db.UserDefinedFunctions` | |
| StoredProcedures | `$db.StoredProcedures` | |
| Views | `$db.Views` | |
| DatabaseTriggers | `$db.Triggers` | |
| TableTriggers | `$table.Triggers` | Nested collection |
| Synonyms | `$db.Synonyms` | |
| FullTextCatalogs | `$db.FullTextCatalogs` | |
| FullTextStopLists | `$db.FullTextStopLists` | |
| ExternalDataSources | `$db.ExternalDataSources` | |
| ExternalFileFormats | `$db.ExternalFileFormats` | |
| SearchPropertyLists | `$db.SearchPropertyLists` | |
| PlanGuides | `$db.PlanGuides` | |
| SecurityPolicies | `$db.SecurityPolicies` | Custom header + SMO script |
| AsymmetricKeys | `$db.AsymmetricKeys` | |
| Certificates | `$db.Certificates` | |
| SymmetricKeys | `$db.SymmetricKeys` | |
| ApplicationRoles | `$db.ApplicationRoles` | |
| DatabaseRoles | `$db.Roles` | |
| DatabaseUsers | `$db.Users` | |
| DatabaseAuditSpecs | `$db.DatabaseAuditSpecifications` | |
| Data (INSERT) | `$db.Tables` | ScriptData mode |

---

## Worker Implementation

### Worker Script Block

```powershell
$workerScriptBlock = {
    param(
        [System.Collections.Concurrent.ConcurrentQueue[hashtable]]$Queue,
        [ref]$ProgressCounter,
        [System.Collections.Concurrent.ConcurrentBag[hashtable]]$ResultsBag,
        [hashtable]$ConnectionInfo,
        [string]$TargetVersion,
        [hashtable]$DefaultScriptingOptions
    )
    
    #region Worker Setup
    
    # Create own SMO connection
    $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ConnectionInfo.Server)
    
    if ($ConnectionInfo.UseIntegratedSecurity) {
        $server.ConnectionContext.LoginSecure = $true
    }
    else {
        $server.ConnectionContext.LoginSecure = $false
        $server.ConnectionContext.Login = $ConnectionInfo.Username
        $server.ConnectionContext.SecurePassword = $ConnectionInfo.Password
    }
    
    if ($ConnectionInfo.TrustServerCertificate) {
        $server.ConnectionContext.TrustServerCertificate = $true
    }
    
    $server.ConnectionContext.ConnectTimeout = $ConnectionInfo.ConnectTimeout
    $server.ConnectionContext.Connect()
    
    $db = $server.Databases[$ConnectionInfo.Database]
    
    # Create own Scripter with prefetch enabled (same as main thread)
    $scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($server)
    $scripter.PrefetchObjects = $true
    $scripter.Options.TargetServerVersion = $TargetVersion
    
    #endregion
    
    #region Work Loop
    
    $workItem = $null
    while ($Queue.TryDequeue([ref]$workItem)) {
        $result = @{
            WorkItemId  = $workItem.WorkItemId
            Success     = $false
            ObjectCount = $workItem.Objects.Count
            Error       = $null
            ObjectType  = $workItem.ObjectType
            Objects     = $workItem.Objects
        }
        
        try {
            # Fetch SMO objects by identifier
            $smoObjects = @()
            foreach ($objId in $workItem.Objects) {
                $smoObj = Get-SmoObjectByIdentifier -Database $db `
                    -ObjectType $workItem.ObjectType `
                    -Schema $objId.Schema `
                    -Name $objId.Name
                
                if ($smoObj) {
                    $smoObjects += $smoObj
                }
            }
            
            if ($smoObjects.Count -eq 0) {
                throw "No SMO objects found for work item"
            }
            
            # Apply scripting options from work item
            $scripter.Options = New-ScriptingOptionsFromHashtable `
                -Defaults $DefaultScriptingOptions `
                -Overrides $workItem.ScriptingOptions
            
            $scripter.Options.FileName = $workItem.OutputPath
            $scripter.Options.AppendToFile = $workItem.AppendToFile
            $scripter.Options.ToFileOnly = $true
            
            # Handle special cases
            if ($workItem.SpecialHandler -eq 'SecurityPolicy') {
                # Write custom header first
                $header = "-- Row-Level Security Policy`n-- NOTE: Ensure predicate functions exist`n"
                [System.IO.File]::WriteAllText($workItem.OutputPath, $header)
                $scripter.Options.AppendToFile = $true
            }
            
            # Script the objects
            $scripter.EnumScript($smoObjects) | Out-Null
            
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
    
    if ($server.ConnectionContext.IsOpen) {
        $server.ConnectionContext.Disconnect()
    }
    
    #endregion
}
```

### Helper Function: Get-SmoObjectByIdentifier

```powershell
function Get-SmoObjectByIdentifier {
    param(
        $Database,
        [string]$ObjectType,
        [string]$Schema,
        [string]$Name
    )
    
    switch ($ObjectType) {
        'Table'              { $Database.Tables[$Name, $Schema] }
        'View'               { $Database.Views[$Name, $Schema] }
        'StoredProcedure'    { $Database.StoredProcedures[$Name, $Schema] }
        'UserDefinedFunction'{ $Database.UserDefinedFunctions[$Name, $Schema] }
        'Schema'             { $Database.Schemas[$Name] }
        'Sequence'           { $Database.Sequences[$Name, $Schema] }
        'Synonym'            { $Database.Synonyms[$Name, $Schema] }
        'UserDefinedType'    { $Database.UserDefinedTypes[$Name, $Schema] }
        # ... etc for all object types
        default { throw "Unknown object type: $ObjectType" }
    }
}
```

---

## Progress Reporting

### Main Thread Progress Loop

```powershell
function Watch-ParallelProgress {
    param(
        [ref]$ProgressCounter,
        [int]$TotalItems,
        [int]$IntervalMs = 500,
        [int]$ReportEveryN = 50
    )
    
    $lastReported = 0
    $startTime = [DateTime]::Now
    
    while ($true) {
        $current = $ProgressCounter.Value
        
        if ($current -ge $TotalItems) {
            # Final report
            Write-Host ("[Parallel] Completed {0}/{0} items (100%)" -f $TotalItems)
            break
        }
        
        # Report at intervals
        if (($current - $lastReported) -ge $ReportEveryN) {
            $pct = [math]::Floor(($current / $TotalItems) * 100)
            $elapsed = ([DateTime]::Now - $startTime).TotalSeconds
            $rate = if ($elapsed -gt 0) { [math]::Round($current / $elapsed, 1) } else { 0 }
            
            Write-Host ("[Parallel] Processed {0}/{1} items ({2}%) - {3}/sec" -f $current, $TotalItems, $pct, $rate)
            $lastReported = $current
        }
        
        Start-Sleep -Milliseconds $IntervalMs
    }
}
```

### Sample Output

```
[Parallel] Starting 5 workers...
[Parallel] Queued 847 work items
[Parallel] Processed 50/847 items (5%) - 12.3/sec
[Parallel] Processed 100/847 items (11%) - 11.8/sec
[Parallel] Processed 150/847 items (17%) - 12.1/sec
...
[Parallel] Completed 847/847 items (100%)
[Parallel] All workers finished in 68.4 seconds
[Parallel] Success: 845, Failed: 2

FAILED ITEMS:
  [ERROR] Table dbo.EncryptedTable: Cannot script Always Encrypted columns
  [ERROR] View Sales.vw_Broken: Invalid object reference
```

---

## File Contention Prevention

**Design Principle**: One output file = one work item. No two workers ever write to the same file.

### How It Works

| GroupBy Mode | Work Item Contains | File |
|--------------|-------------------|------|
| single | 1 object | `dbo.Customers.sql` |
| schema | All objects in schema | `001_dbo.sql` |
| all | All objects of type | `001_AllTables.sql` |

When building work items:
- GroupBy single: Create one work item per object
- GroupBy schema: Create one work item per schema (all objects in that schema bundled)
- GroupBy all: Create one work item for entire object type

This guarantees no file contention without any locking.

---

## Error Handling

### Worker Errors

- Workers catch exceptions per work item
- Record error in ResultsBag with full context
- Continue processing next work item
- Never stop other workers

### Aggregation

```powershell
$failures = $ResultsBag | Where-Object { -not $_.Success }

if ($failures.Count -gt 0) {
    Write-Host ""
    Write-Host "FAILED ITEMS ($($failures.Count)):" -ForegroundColor Red
    
    foreach ($failure in $failures) {
        Write-Host "  [ERROR] $($failure.ObjectType) " -NoNewline
        $objNames = ($failure.Objects | ForEach-Object { "$($_.Schema).$($_.Name)" }) -join ', '
        Write-Host "$objNames" -NoNewline -ForegroundColor Yellow
        Write-Host ": $($failure.Error)" -ForegroundColor Red
    }
}
```

### Exit Code

```powershell
$exitCode = if ($failures.Count -gt 0) { 1 } else { 0 }
exit $exitCode
```

---

## Implementation Phases

### Phase 1: Foundation (Est. 4 hours)

- [ ] Add `-Parallel` switch parameter to `Export-SqlServerSchema.ps1`
- [ ] Add `parallel` section to YAML schema (`export-import-config.schema.json`)
- [ ] Create `New-ExportWorkItem` function
- [ ] Create `Build-WorkItemQueue` function (mirrors current export logic, outputs work items)
- [ ] Add `Ensure-OutputDirectories` function (pre-create all folders)
- [ ] Unit tests for work item creation

### Phase 2: Worker Infrastructure (Est. 6 hours)

- [ ] Create `Initialize-RunspacePool` function
- [ ] Create `$workerScriptBlock` with full implementation
- [ ] Create `Get-SmoObjectByIdentifier` helper
- [ ] Create `New-ScriptingOptionsFromHashtable` helper
- [ ] Implement worker connection setup with same auth options as main
- [ ] Implement worker prefetch configuration
- [ ] Integration test: single worker processes queue

### Phase 3: Progress & Results (Est. 3 hours)

- [ ] Implement atomic progress counter with `[Interlocked]::Increment`
- [ ] Create `Watch-ParallelProgress` function
- [ ] Implement results aggregation
- [ ] Implement error collection and reporting
- [ ] Test progress display accuracy

### Phase 4: Integration (Est. 4 hours)

- [ ] Wire parallel path into `Export-DatabaseObjects`
- [ ] Handle non-parallelizable objects (FileGroups, etc.) sequentially first
- [ ] Ensure sequential mode still works (no regression)
- [ ] Test with all groupBy modes (single, schema, all)
- [ ] Test with various object types
- [ ] Test with data export included

### Phase 5: Polish (Est. 3 hours)

- [ ] Add logging for parallel operations
- [ ] Handle edge cases:
  - Empty database
  - Single object
  - Worker connection failure
  - Queue exhaustion race condition
- [ ] Update README.md with parallel export documentation
- [ ] Add parallel mode integration tests
- [ ] Performance benchmarking: parallel vs sequential

**Total Estimated Time**: 20 hours

---

## Testing Strategy

### Unit Tests

1. `New-ExportWorkItem` produces correct structure
2. `Build-WorkItemQueue` respects groupBy settings
3. `Get-SmoObjectByIdentifier` finds objects correctly
4. Work items for all object types are valid

### Integration Tests

1. Parallel export produces identical output to sequential
2. Error handling: one bad object doesn't stop export
3. Progress reporting accuracy
4. Metrics are correctly aggregated
5. All groupBy modes work correctly
6. Data export works in parallel

### Performance Tests

| Scenario | Sequential | Parallel (5 workers) | Expected Improvement |
|----------|------------|---------------------|---------------------|
| 100 objects | Baseline | ? | May be slower (overhead) |
| 500 objects | Baseline | ? | ~2-3x faster |
| 2000 objects | Baseline | ? | ~3-4x faster |

---

## Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| SMO not thread-safe | Low | High | Each worker has own connection/scripter |
| Memory exhaustion | Low | Medium | Don't prefetch entire DB; work items are small |
| Connection pool exhaustion | Medium | Medium | Limit maxWorkers to 20; default 5 |
| Slower for small DBs | High | Low | Document; users can disable parallel |
| Complex debugging | Medium | Medium | Good logging; error details in results |

---

## Final Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Work item splitting | No | Keep simple; avoid file naming complexity |
| Default workers | 5 | Conservative; won't overwhelm modest machines |
| Worker prefetch | Yes | Same as main thread for consistency |
| Progress display | Aggregated | Keep console clean; report every N items |
| Error handling | Continue | Don't stop all workers for one failure |
| File contention | Prevented by design | One file = one work item |
| Parallel opt-in | Yes | `-Parallel` switch; disabled by default |

---

## Appendix: PowerShell Runspace Pool Pattern

```powershell
# Create runspace pool
$sessionState = [InitialSessionState]::CreateDefault()
$runspacePool = [RunspaceFactory]::CreateRunspacePool(1, $maxWorkers, $sessionState, $Host)
$runspacePool.Open()

# Create and start workers
$workers = @()
for ($i = 0; $i -lt $maxWorkers; $i++) {
    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $runspacePool
    $ps.AddScript($workerScriptBlock)
    $ps.AddParameters(@{
        Queue = $workQueue
        ProgressCounter = $progressCounter
        ResultsBag = $resultsBag
        ConnectionInfo = $connectionInfo
        TargetVersion = $targetVersion
        DefaultScriptingOptions = $defaultOptions
    })
    
    $workers += @{
        PowerShell = $ps
        Handle = $ps.BeginInvoke()
    }
}

# Wait for all workers (with progress monitoring)
# ... progress loop ...

# Cleanup
foreach ($worker in $workers) {
    $worker.PowerShell.EndInvoke($worker.Handle)
    $worker.PowerShell.Dispose()
}
$runspacePool.Close()
$runspacePool.Dispose()
```
