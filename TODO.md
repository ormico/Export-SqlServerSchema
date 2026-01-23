# TODO

## High Priority Issues

### FileGroup Size/Growth Remapping (CRITICAL)

**Problem**: When exporting/importing FileGroups, we currently remap filename and path but NOT initial file size and growth factor. This causes FileGroup failures on dev systems if production sizes are too large (e.g., 100GB initial size).

**Impact**: Dev/test imports can fail with disk space errors even though FileGroup paths are correctly remapped.

**Solution**:
1. Add FileGroup size/growth remapping in Import-SqlServerSchema.ps1
2. Default to 1024 KB initial size for all FileGroups
3. Add config file setting in import section:
   ```yaml
   import:
     fileGroups:
       defaultInitialSize: "1024KB"  # or "10MB", "1GB", etc.
       defaultGrowth: "1024KB"       # or "10%"
   ```
4. Parse SIZE and FILEGROWTH from exported FileGroup SQL
5. Replace with configured/default values during import

**Files to Modify**:
- `Import-SqlServerSchema.ps1` - Add size/growth remapping logic
- `export-import-config.schema.json` - Add fileGroups.defaultInitialSize and defaultGrowth
- `export-import-config.example.yml` - Add example configuration

**Priority**: HIGH - Blocks dev/test imports for large production databases

---

## Feature Development Order

1. ~~**Parallel Export**~~ ✅ **COMPLETE** - January 22, 2026
2. **FileGroup Size Remapping** (HIGH PRIORITY) - Blocks dev/test imports
3. **Incremental Export** (NEXT) - After FileGroup fix

---

## Parallel Export Feature ✅ COMPLETE

**Status**: Implementation complete, bug fix applied, ready for testing

**Implementation Summary**:
- ✅ Added `-Parallel` switch parameter
- ✅ PowerShell Runspace Pool with configurable workers (default 5)
- ✅ 30 helper functions for all object types
- ✅ Worker scriptblock with SMO connection + Scripter per worker
- ✅ Work items with identifiers only (SMO-safe)
- ✅ Non-parallelizable objects handled sequentially
- ✅ All 3 grouping modes supported (single/schema/all)
- ✅ Special handlers (TableTriggers, Indexes, ForeignKeys, SecurityPolicies)
- ✅ Configuration via YAML and command line
- ✅ Progress monitoring with atomic counters
- ✅ Error aggregation and fallback to sequential
- ✅ **BUG FIX**: Convert ArrayList to ConcurrentQueue for worker threads

**Files Created** (5):
1. `parallel-implementation.ps1` - Worker infrastructure
2. `parallel-work-items-part1.ps1` - First 8 helpers
3. `parallel-work-items-part2.ps1` - Next 6 helpers  
4. `parallel-work-items-part3.ps1` - Final 16 helpers
5. `parallel-orchestrators.ps1` - Orchestration functions

**Files Modified** (4):
1. `Export-SqlServerSchema.ps1` - Dot-sourcing + parallel branch + command line override fix
2. `export-import-config.schema.json` - Parallel config schema
3. `export-import-config.example.yml` - Config example
4. `tests/run-integration-test.ps1` - Added Step 4.5 for parallel validation

**Testing**:
- Integration test: `cd tests && pwsh ./run-integration-test.ps1` (uses .env for credentials)
- Performance test: `cd tests && pwsh ./run-perf-test.ps1` (uses .env for credentials)
- **NOTE**: Tests read credentials from `tests/.env` file automatically - no manual input needed

**Test Commands** (all use .env automatically):
```powershell
# Full integration test (sequential + parallel validation)
cd d:\Export-SqlServerSchema\tests
pwsh .\run-integration-test.ps1

# Performance test (measures speedup)
cd d:\Export-SqlServerSchema\tests
pwsh .\run-perf-test.ps1
```

**Next Steps**:
1. Run integration test to validate bug fix
2. Run performance test to measure speedup
3. Update README.md with usage examples
4. Update CHANGELOG.md

---

## Export-DatabaseObjects Output Capture Issue

**Problem**: allow only exporting changed items. 

Either allow passing in a date and checking sql server for items that changed since that date or targetting a previous export and looking at metadata for the last export's start date to determine what object changed since last export.

Build the list according to the config the same as always but filter out objects that haven't changed and only export object that have changed.

Default to exporting to a new folder.

A utility to combine 2 exports into 1 new folder structure could be useful but it would have to be careful. If some items are using all or schema grouping the files would have to be carefully combined.

**Problem**: All `Write-Output` statements in the `Export-DatabaseObjects` function are being captured and hidden from console output.

**Root Cause**: 
- Line 4536: `$schemaResult = Export-DatabaseObjects -Database $smDatabase -OutputDir $exportDir -Scripter $scripter -TargetVersion $sqlVersion`
- When function output is captured into a variable in PowerShell, ALL output stream content (including `Write-Output`) gets captured
- Only `Write-Host` bypasses capture because it writes directly to the host

**Current Behavior**:
- ✅ `Write-Host` from `Write-ProgressHeader` displays correctly (e.g., `== Tables ==`)
- ✅ Progress percentages display correctly
- ❌ All `Write-Output` statements are hidden (e.g., `Exporting security objects...`, `Found X table(s)`, etc.)

**Current Usage**:
- The `$schemaResult` variable is used ONLY for metrics collection (lines 4540-4547):
  - `TotalObjects`
  - `SuccessCount` 
  - `FailCount`
- The captured `Write-Output` text is discarded/unused

**Examples of Hidden Output**:
- `Write-Output 'Exporting security objects...'` (line 3609)
- `Write-Output 'Exporting filegroups...'` (line 1154)
- `Write-Output "  Found $($tables.Count) table(s) to export"` (line 1862)
- Many more throughout Export-DatabaseObjects function

**Potential Solutions**:
1. **Change Write-Output to Write-Host** in Export-DatabaseObjects
   - Pros: Simple, immediate fix
   - Cons: Mixing output paradigms, harder to suppress if needed

2. **Use Write-Information with -InformationAction Continue**
   - Pros: Proper PowerShell stream usage
   - Cons: Requires callers to set InformationAction

3. **Return metrics via [PSCustomObject] with explicit type**
   - Pros: Clean separation of return value from output
   - Cons: Requires refactoring how function returns are handled

4. **Use $script: scoped metrics variable instead of return value**
   - Pros: Avoids output capture entirely
   - Cons: More global state, less functional design

5. **Call function without capture, set metrics via reference parameter**
   - Pros: Clean separation
   - Cons: More complex function signature

**Same Issue Applies To**:
- `Export-TableData` function (line 4551) - also captured into `$dataResult`

**Recommendation**: 
Evaluate whether metrics collection justifies the loss of user feedback. Consider option 4 (script-scoped metrics) since metrics are already being collected in `$script:Metrics` hashtable.

---

## Parallel Export Feasibility Analysis

**Context**: Current export is sequential by object type. Question raised about whether parallel export would overload SQL Server.

**How SMO Export Works**:
1. **Metadata Retrieval** (SQL Server → Client):
   - SMO queries system catalog views (`sys.tables`, `sys.columns`, `sys.indexes`, etc.)
   - Fetches object properties, definitions, permissions, extended properties
   - This is where SQL Server load occurs

2. **Script Generation** (Client-side only):
   - Local .NET SMO library generates T-SQL scripts from cached metadata
   - Uses local CPU/memory, no server interaction
   - Target version compatibility handled locally

3. **File I/O** (Client-side only):
   - Scripts written to local filesystem
   - No SQL Server involvement

**Current Optimizations**:
- Line 4533: `$scripter.PrefetchObjects = $true` - enables batch metadata loading
- Line 1146: Collections are cached (e.g., `$tables = @($Database.Tables | ...)`)
- Prefetch loads bulk metadata upfront rather than per-object queries

**Server Load Sources**:
- ✅ Initial collection enumeration (system catalog queries)
- ✅ Prefetch batch loads (if enabled)
- ❌ NOT from script generation (happens locally)
- ❌ NOT from file I/O (local filesystem)

**Parallel Export Analysis**:
- **Server load concern may be overstated** given prefetch optimization
- With `PrefetchObjects = $true`, metadata is already cached after initial fetch
- Parallel script generation would only increase **local** CPU/memory usage
- **Potential benefit**: Multiple CPU cores generating scripts simultaneously
- **Risk**: If prefetch doesn't fully cache, parallel queries could cause system catalog contention

**Recommendation**:
Test parallel export with prefetch enabled. The bottleneck is likely script generation (CPU-bound, local) rather than metadata retrieval. Consider:
1. Prefetch all collections first (ensure complete cache)
2. Parallel script generation by object type (Tables, Views, Procedures in parallel)
3. Monitor SQL Server DMVs during test to confirm no catalog lock contention

**Open Questions**:
- Does `PrefetchObjects = $true` fully cache all metadata needed by `EnumScript()`?
- Are there additional per-object metadata queries not covered by prefetch?
- What's the actual bottleneck: metadata retrieval or script generation?

---

## Parallel Export Implementation Plan

### Overview

Add optional parallel processing for export to leverage multiple CPU cores during script generation.

### Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 1: ENUMERATION                         │
│                    (Sequential, Main Thread)                    │
├─────────────────────────────────────────────────────────────────┤
│  1. Connect to database                                         │
│  2. Prefetch all collections (tables, views, procs, etc.)       │
│  3. Handle special object types sequentially:                   │
│     - FileGroups (custom string builder, SQLCMD vars)           │
│     - DatabaseScopedConfigs (not SMO scriptable)                │
│     - DatabaseScopedCredentials (documentation only)            │
│  4. For each standard object type:                              │
│     - Determine grouping mode (single/schema/all)               │
│     - Create work items with IDENTIFIERS (not SMO objects)      │
│     - Add to ConcurrentQueue                                    │
│  5. Pre-create all output directories                           │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 2: PARALLEL SCRIPTING                  │
│                    (N Worker Runspaces)                         │
├─────────────────────────────────────────────────────────────────┤
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐        │
│  │ Worker 1 │  │ Worker 2 │  │ Worker 3 │  │ Worker N │        │
│  │ Own Conn │  │ Own Conn │  │ Own Conn │  │ Own Conn │        │
│  │ Scripter │  │ Scripter │  │ Scripter │  │ Scripter │        │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  └────┬─────┘        │
│       └─────────────┴──────┬──────┴─────────────┘               │
│                            ▼                                    │
│              ┌─────────────────────────────┐                    │
│              │  ConcurrentQueue<WorkItem>  │                    │
│              └─────────────────────────────┘                    │
│                            │                                    │
│              ┌─────────────┴─────────────┐                      │
│              ▼                           ▼                      │
│     ┌─────────────────┐        ┌─────────────────┐              │
│     │ Progress Queue  │        │ Results Bag     │              │
│     │ (for display)   │        │ (metrics/errors)│              │
│     └─────────────────┘        └─────────────────┘              │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    PHASE 3: AGGREGATION                         │
│                    (Sequential, Main Thread)                    │
├─────────────────────────────────────────────────────────────────┤
│  1. Wait for all workers to complete                            │
│  2. Aggregate metrics (totals only)                             │
│  3. Report any errors collected                                 │
│  4. Display summary                                             │
└─────────────────────────────────────────────────────────────────┘
```

### Critical Constraint: SMO Object Serialization

**Problem**: SMO objects are bound to their connection. Cannot pass SMO object to another runspace.

**Solution**: Work items store **identifiers only**. Workers re-fetch objects using their own connection.

### Work Item Structure

```powershell
[PSCustomObject]@{
    # Identification
    WorkItemId       = [guid]::NewGuid()
    ObjectType       = 'Table'           # Table, View, StoredProcedure, etc.
    
    # Grouping Mode
    GroupingMode     = 'single'          # single, schema, all
    
    # Object Identifiers (NOT SMO objects - these are serializable)
    Objects          = @(
        @{ Schema = 'dbo'; Name = 'Customers' }
    )
    
    # Output Configuration  
    OutputPath       = 'D:\export\09_Tables_PrimaryKey\dbo.Customers.sql'
    AppendToFile     = $false
    
    # Scripting Options (serializable hashtable, not SMO ScriptingOptions)
    ScriptingOptions = @{
        DriPrimaryKey    = $true
        DriForeignKeys   = $false
        Indexes          = $false
    }
    
    # For special cases
    SpecialHandler   = $null             # 'SecurityPolicy', etc.
    CustomData       = $null             # Handler-specific data
}
```

### Object Type Handling

| Object Type | Parallel? | Notes |
|-------------|-----------|-------|
| FileGroups | No | Custom string builder, SQLCMD vars - run first |
| DatabaseScopedConfigs | No | Not SMO scriptable - run first |
| DatabaseScopedCredentials | No | Documentation only - run first |
| Schemas | Yes | Standard SMO scripting |
| Sequences | Yes | Standard SMO scripting |
| PartitionFunctions | Yes | Standard SMO scripting |
| PartitionSchemes | Yes | Standard SMO scripting |
| Types | Yes | Standard SMO scripting |
| XmlSchemaCollections | Yes | Standard SMO scripting |
| Tables | Yes | Standard SMO scripting |
| ForeignKeys | Yes | Standard SMO scripting |
| Indexes | Yes | Standard SMO scripting |
| Defaults | Yes | Standard SMO scripting |
| Rules | Yes | Standard SMO scripting |
| Functions | Yes | Standard SMO scripting |
| StoredProcedures | Yes | Standard SMO scripting |
| Views | Yes | Standard SMO scripting |
| Triggers | Yes | Standard SMO scripting |
| Synonyms | Yes | Standard SMO scripting |
| FullTextCatalogs | Yes | Standard SMO scripting |
| ExternalDataSources | Yes | Standard SMO scripting |
| SecurityPolicies | Yes | Custom header + SMO script |
| Security (Keys/Certs/Roles/Users) | Yes | Standard SMO scripting |
| Data (INSERT) | Yes | ScriptData mode |

### Configuration

```yaml
export:
  parallel:
    enabled: true          # Default: false (opt-in)
    maxWorkers: 5          # Default: 5, range 1-20
    progressInterval: 50   # Report every N items processed
```

### Design Decisions

1. **Worker Connection Strategy**: 
   - Create SMO connection once per worker at startup
   - Reuse for all work items (more efficient)
   - Each worker has own Scripter instance

2. **Progress Reporting**:
   - Workers increment atomic counter after each work item
   - Main thread polls counter periodically (every 500ms)
   - Display: `[Parallel] Processed 150/500 items (30%)`
   - Keep console output minimal

3. **Error Handling**:
   - Continue on error (don't stop other workers)
   - Collect errors in ConcurrentBag
   - Report all failures at end
   - Exit code reflects any failures

4. **Memory Management**:
   - Queue all work items upfront (simpler)
   - For very large DBs (10K+ objects), consider batching
   - Worker connections disposed after completion

5. **Sequential Fallback**:
   - Special handlers run sequentially (Phase 1)
   - If parallel setup fails, fall back to current sequential

### Implementation Phases

#### Phase 1: Foundation
- [ ] Add `-Parallel` switch parameter
- [ ] Add parallel config section to YAML schema
- [ ] Create `New-WorkItem` function
- [ ] Create work item queue builder (mirrors current export logic)
- [ ] Add directory pre-creation step

#### Phase 2: Worker Infrastructure
- [ ] Create runspace pool setup function
- [ ] Create worker script block
- [ ] Implement worker SMO connection/scripter setup
- [ ] Implement work item dequeue and dispatch
- [ ] Implement results collection (success/fail/metrics)

#### Phase 3: Progress & Aggregation
- [ ] Implement atomic progress counter
- [ ] Implement main thread progress polling/display
- [ ] Implement error aggregation and reporting
- [ ] Implement metrics aggregation

#### Phase 4: Integration
- [ ] Wire parallel path into Export-DatabaseObjects
- [ ] Handle special object types (FileGroups, etc.) sequentially first
- [ ] Test with various grouping modes
- [ ] Performance benchmarking vs sequential

#### Phase 5: Polish
- [ ] Add logging for parallel operations
- [ ] Handle edge cases (empty queue, connection failures)
- [ ] Update documentation
- [ ] Add integration tests for parallel mode

### Worker Script Block (Pseudocode)

```powershell
$workerScript = {
    param($Queue, $ProgressCounter, $ResultsBag, $ConnInfo, $TargetVersion, $ScriptingDefaults)
    
    # Setup own connection
    $server = [Microsoft.SqlServer.Management.Smo.Server]::new($ConnInfo.Server)
    # ... auth setup ...
    $db = $server.Databases[$ConnInfo.Database]
    $scripter = [Microsoft.SqlServer.Management.Smo.Scripter]::new($server)
    $scripter.Options.TargetServerVersion = $TargetVersion
    
    # Process work items
    $workItem = $null
    while ($Queue.TryDequeue([ref]$workItem)) {
        try {
            # Fetch SMO object(s) by identifier
            $smoObjects = foreach ($obj in $workItem.Objects) {
                Get-SmoObject -Database $db -Type $workItem.ObjectType -Schema $obj.Schema -Name $obj.Name
            }
            
            # Configure scripter for this work item
            Apply-ScriptingOptions -Scripter $scripter -Options $workItem.ScriptingOptions
            $scripter.Options.FileName = $workItem.OutputPath
            $scripter.Options.AppendToFile = $workItem.AppendToFile
            
            # Script
            $scripter.EnumScript($smoObjects) | Out-Null
            
            # Record success
            $ResultsBag.Add(@{ WorkItemId = $workItem.WorkItemId; Success = $true })
        }
        catch {
            # Record failure
            $ResultsBag.Add(@{ 
                WorkItemId = $workItem.WorkItemId
                Success = $false 
                Error = $_.Exception.Message
                ObjectType = $workItem.ObjectType
                Objects = $workItem.Objects
            })
        }
        
        # Increment progress
        [System.Threading.Interlocked]::Increment($ProgressCounter)
    }
    
    # Cleanup
    $server.ConnectionContext.Disconnect()
}
```

### Final Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Work item splitting | No | Keep simple, avoid file naming complexity |
| Default workers | 5 | Conservative, won't overwhelm modest machines |
| Worker count configurable | Yes | Via `export.parallel.maxWorkers` in YAML |
| Worker prefetch | Yes | Same as main thread (`PrefetchObjects = $true`) |
| File contention | N/A | Prevented by design - one file = one work item |
| Parallel opt-in | Yes | `-Parallel` switch, disabled by default |

**See full design document**: [docs/PARALLEL_EXPORT_DESIGN.md](docs/PARALLEL_EXPORT_DESIGN.md)

---

## Incremental/Delta Export Feature

**Goal**: Export only objects that have changed since a previous export.

### Key Requirements

1. **Object List File**: Every export generates `_object_list.json` with objectId for delete/rename detection
2. **GroupBy Restriction**: Incremental export requires `groupBy: single` mode
3. **Merge Utility**: Deferred until core incremental is stable (only works with single mode anyway)

### SQL Server Modification Tracking

SQL Server tracks object modification dates via `sys.objects.modify_date`:

```sql
SELECT name, type_desc, create_date, modify_date 
FROM sys.objects 
WHERE modify_date > '2026-01-15'
  AND is_ms_shipped = 0;
```

### Proposed Approaches

1. **Date-based**: `-ModifiedSince "2026-01-15"` parameter
2. **Previous export reference**: `-DeltaFrom "D:\Exports\prev_export"` 
3. **Auto-detect latest**: `-DeltaFromLatest` switch

### Why GroupBy Schema/All Doesn't Work

With grouped files, multiple objects are in one file. Problems:
- Can't merge incremental (single file) into grouped base without SQL parsing
- Can't patch (would lose unchanged objects or create duplicates)
- Tables/FileGroups can't be patched safely
- Deletes would need generated DROP scripts

**Decision**: Document limitation, recommend `groupBy: single` for incremental workflows.

**See full feasibility analysis**: [docs/INCREMENTAL_EXPORT_FEASIBILITY.md](docs/INCREMENTAL_EXPORT_FEASIBILITY.md)
