# Incremental Export Feature - Feasibility Analysis

**Date**: January 22, 2026  
**Status**: Feasibility Analysis Complete - VIABLE

---

## Executive Summary

SQL Server provides metadata tracking that makes incremental schema export **feasible**. The `sys.objects.modify_date` column tracks the last DDL modification date for most database objects, enabling detection of changed objects since a previous export.

---

## SQL Server Object Modification Tracking

### sys.objects Catalog View

SQL Server's `sys.objects` view contains these key columns:

| Column | Type | Description |
|--------|------|-------------|
| `create_date` | datetime | Date the object was created |
| `modify_date` | datetime | Date the object was last modified by using an ALTER statement |

**Critical Note**: Microsoft documentation states:
> If the object is a **table or a view**, `modify_date` also changes when an **index** on the table or view is created or altered.

This means table `modify_date` may change even when the table definition itself hasn't changed (only an index was added).

### What Triggers modify_date Update

| Action | Updates modify_date? | Notes |
|--------|---------------------|-------|
| CREATE statement | Yes | Sets both create_date and modify_date |
| ALTER statement | Yes | Updates modify_date |
| DROP + recreate | Yes | New object, new dates |
| Index create/alter on table | Yes | Even though table itself unchanged |
| Adding FK constraint | Yes | ALTER TABLE |
| Grant/Revoke permissions | No | Security, not object definition |
| TRUNCATE TABLE | No | Not a DDL change |
| INSERT/UPDATE/DELETE | No | DML, not DDL |
| DBCC CHECKIDENT | Unclear | May not update |

### Query Example

```sql
-- Find all objects modified in last 7 days
SELECT 
    SCHEMA_NAME(schema_id) AS schema_name,
    name AS object_name,
    type_desc,
    create_date,
    modify_date
FROM sys.objects
WHERE modify_date > DATEADD(day, -7, GETDATE())
  AND is_ms_shipped = 0
ORDER BY modify_date DESC;
```

---

## Object Types Coverage

### Objects with modify_date in sys.objects

| Object Type | type_desc | Has modify_date? |
|-------------|-----------|------------------|
| Tables | USER_TABLE | Yes |
| Views | VIEW | Yes |
| Stored Procedures | SQL_STORED_PROCEDURE | Yes |
| Functions (scalar) | SQL_SCALAR_FUNCTION | Yes |
| Functions (TVF) | SQL_TABLE_VALUED_FUNCTION | Yes |
| Functions (inline TVF) | SQL_INLINE_TABLE_VALUED_FUNCTION | Yes |
| Triggers (DML) | SQL_TRIGGER | Yes |
| Check Constraints | CHECK_CONSTRAINT | Yes |
| Default Constraints | DEFAULT_CONSTRAINT | Yes |
| Foreign Keys | FOREIGN_KEY_CONSTRAINT | Yes |
| Primary Keys | PRIMARY_KEY_CONSTRAINT | Yes |
| Unique Constraints | UNIQUE_CONSTRAINT | Yes |
| Synonyms | SYNONYM | Yes |
| Sequences | SEQUENCE_OBJECT | Yes |

### Objects NOT in sys.objects (Require Separate Tracking)

| Object Type | Catalog View | Has modify_date? |
|-------------|-------------|------------------|
| Schemas | sys.schemas | **No** - only create_date via sys.objects type='S' |
| Users | sys.database_principals | **Yes** - modify_date column |
| Roles | sys.database_principals | **Yes** - modify_date column |
| Indexes | sys.indexes | **No** - check table modify_date |
| Partition Functions | sys.partition_functions | **Yes** - create_date, modify_date |
| Partition Schemes | sys.partition_schemes | **Yes** - create_date, modify_date |
| Types (UDT) | sys.types | **Yes** - via sys.assembly_types or sys.objects |
| XML Schema Collections | sys.xml_schema_collections | **No** - only create_date |
| Full-Text Catalogs | sys.fulltext_catalogs | **No** - only create_date |
| Security Policies (RLS) | sys.security_policies | **Yes** - create_date, modify_date |
| FileGroups | sys.filegroups | **No** - must export always |
| Database-Scoped Configs | N/A | **No** - must export always |

### DDL Triggers

DDL triggers are **not in sys.objects**. They're in `sys.triggers`:

```sql
SELECT name, create_date, modify_date 
FROM sys.triggers 
WHERE parent_class_desc = 'DATABASE';
```

---

## Implementation Approaches

### Approach 1: Date-Based Filtering (Simplest)

**Command-line parameter:**
```powershell
.\Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -ModifiedSince "2026-01-15"
```

**Implementation:**
```powershell
# Query modified objects
$cutoffDate = [datetime]$ModifiedSince

$query = @"
SELECT 
    SCHEMA_NAME(schema_id) AS SchemaName,
    name AS ObjectName,
    type_desc AS ObjectType,
    modify_date
FROM sys.objects
WHERE modify_date >= @CutoffDate
  AND is_ms_shipped = 0
ORDER BY type_desc, schema_name, name
"@

$modifiedObjects = Invoke-SqlCmd -Query $query -Variable "CutoffDate=$cutoffDate"
```

**Pros:**
- Simple to implement
- User explicitly controls the date
- Works without previous export metadata

**Cons:**
- User must track the date themselves
- May miss objects if date is wrong
- Can't automatically determine "since last export"

---

### Approach 2: Previous Export Reference (More Robust)

**Command-line parameter:**
```powershell
.\Export-SqlServerSchema.ps1 -Server localhost -Database MyDb -DeltaFrom "D:\Exports\localhost_MyDb_20260115_120000"
```

**Implementation:**
1. Read metadata from previous export (e.g., `_export_metadata.json`)
2. Extract export start timestamp
3. Query objects modified since that timestamp
4. Export only changed objects
5. Write new metadata file

**Metadata file structure:**
```json
{
  "exportVersion": "1.0",
  "exportStartTime": "2026-01-15T12:00:00Z",
  "exportEndTime": "2026-01-15T12:05:32Z",
  "serverName": "localhost",
  "databaseName": "MyDb",
  "objectCounts": {
    "Tables": 45,
    "Views": 12,
    "StoredProcedures": 87
  }
}
```

**Pros:**
- Automatically determines correct cutoff date
- Provides audit trail
- Can include object hashes for content comparison

**Cons:**
- Requires previous export to exist
- More complex implementation
- Must handle missing/corrupted metadata

---

### Approach 3: Hybrid (Recommended)

Support **both** approaches:

```powershell
# Option A: Explicit date
-ModifiedSince "2026-01-15"

# Option B: Reference previous export
-DeltaFrom "D:\Exports\localhost_MyDb_20260115_120000"

# Option C: Auto-detect latest export in OutputPath
-DeltaFromLatest
```

---

## Object List File (Required for Delete Detection)

Each export must include an object list file to enable detection of dropped objects.

**File**: `_object_list.json`

```json
{
  "exportTime": "2026-01-15T12:00:00Z",
  "serverTime": "2026-01-15T12:00:00Z",
  "objects": [
    { "type": "Table", "schema": "dbo", "name": "Customers", "objectId": 12345 },
    { "type": "Table", "schema": "dbo", "name": "Orders", "objectId": 12346 },
    { "type": "View", "schema": "dbo", "name": "vw_ActiveCustomers", "objectId": 12400 },
    { "type": "StoredProcedure", "schema": "dbo", "name": "usp_GetOrders", "objectId": 12500 }
  ]
}
```

**Why object_id?**: Enables detection of renamed objects (same object_id, different name).

**Delete Detection Logic**:
```powershell
$previousObjects = (Get-Content "$DeltaFrom\_object_list.json" | ConvertFrom-Json).objects
$currentObjects = Get-CurrentDbObjectList -Database $Database

# Find dropped objects (in previous but not in current by object_id)
$droppedObjects = $previousObjects | Where-Object {
    $prev = $_
    -not ($currentObjects | Where-Object { $_.objectId -eq $prev.objectId })
}

# Find renamed objects (same object_id, different name)
$renamedObjects = $previousObjects | Where-Object {
    $prev = $_
    $current = $currentObjects | Where-Object { $_.objectId -eq $prev.objectId }
    $current -and ($current.name -ne $prev.name -or $current.schema -ne $prev.schema)
}
```

---

## GroupBy Mode Restriction

> **IMPORTANT**: Incremental export only works reliably with `groupBy: single` mode.

### Why GroupBy Schema/All Is Problematic

With `groupBy: schema` or `groupBy: all`, multiple objects are combined into single files:

```
# groupBy: all
14_Programmability/001_StoredProcedures.sql  ← Contains ALL procedures

# groupBy: schema  
14_Programmability/001_dbo.sql               ← Contains all dbo procedures
14_Programmability/002_Sales.sql             ← Contains all Sales procedures
```

**Problems with incremental + grouped files**:

1. **Can't merge incrementals**: If `dbo.GetOrders` changes, the incremental exports just that procedure. But the base export has all dbo procedures in one file. Merging would require:
   - Parsing SQL to identify object boundaries
   - Extracting the old version of `dbo.GetOrders`
   - Replacing with new version
   - This is fragile and error-prone

2. **Patch pattern doesn't work**: 
   - Can't just overwrite files (would lose unchanged objects)
   - Can't append (would create duplicates)
   - Tables can't be "patched" (ALTER TABLE has limits vs CREATE TABLE)
   - FileGroups require special handling
   - Deletes would require generating DROP scripts

3. **No reliable merge strategy**: Without parsing SQL, there's no way to combine a grouped base export with a single-file incremental.

### Recommendation

```yaml
export:
  # For incremental export workflows, use groupBy: single
  groupBy: single
  
  incremental:
    enabled: true
```

If users want grouped files for deployment convenience, they should:
1. Do a full export with `groupBy: schema` or `groupBy: all`
2. Not use incremental mode with grouped exports

---

## Merge Utility (Future / Low Priority)

A merge utility could combine incremental exports into a full baseline, but:

- **Only works with `groupBy: single`** (one file per object)
- **Not feasible for grouped files** without SQL parsing
- **Deferred** until core incremental functionality is proven

### Potential Future Design

```powershell
# Only for groupBy: single exports
.\Merge-SqlServerExports.ps1 -BaseExport "D:\Exports\Full_20260101" `
                             -DeltaExport "D:\Exports\Delta_20260115" `
                             -OutputPath "D:\Exports\Merged_20260115"
```

**Logic** (groupBy: single only):
1. Copy all files from BaseExport to OutputPath
2. For each file in DeltaExport: Replace corresponding file in OutputPath
3. Remove files for dropped objects (from object list comparison)
4. Merge metadata and object list files

---

## Limitations and Caveats

### 1. Index Changes Don't Create New Files

If only an index changes on a table, the table's `modify_date` updates, but re-exporting the table with PK-only options won't capture the index change. The index export is separate.

**Solution**: When table `modify_date` changes, also re-export its indexes.

### 2. Dropped Objects Not Detected

If an object was deleted since the last export, querying `sys.objects` won't show it (it no longer exists).

**Solution**: The `_object_list.json` file (see above) stores the complete object list from each export. Compare previous and current lists to detect drops.

### 3. Renamed Objects

If an object is renamed (via `sp_rename`), it appears as:
- "New" object created (different name)
- "Old" object dropped

**Solution**: The `_object_list.json` includes `objectId` which persists across renames. Same object_id with different name = rename detected.

### 4. Objects Without modify_date

Some objects don't have `modify_date`:
- XML Schema Collections
- Full-Text Catalogs
- FileGroups
- Database-scoped configurations

**Solution**: Always re-export these object types in incremental mode, or hash the previous export's script content and compare.

### 5. Clock Skew

If the SQL Server's clock and the client's clock differ, date comparisons may be incorrect.

**Solution**: Always use SQL Server's time (`GETDATE()`) for comparisons, and store the server time in metadata.

---

## Permissions Required

The user needs `SELECT` permission on these system catalog views:

| View | Objects |
|------|---------|
| sys.objects | Tables, views, procedures, functions, triggers, constraints, synonyms, sequences |
| sys.database_principals | Users, roles |
| sys.indexes | Indexes (via table modify_date) |
| sys.partition_functions | Partition functions |
| sys.partition_schemes | Partition schemes |
| sys.security_policies | Row-level security policies |

These are typically granted to any user with `VIEW DEFINITION` permission or database readers.

---

## YAML Configuration

```yaml
export:
  incremental:
    enabled: true
    mode: "auto"          # auto, date, path
    # mode=auto: Use -DeltaFromLatest behavior
    # mode=date: Require -ModifiedSince parameter
    # mode=path: Require -DeltaFrom parameter
    
    includeDroppedDetection: true   # Report objects that were dropped
    alwaysExportTypes:              # Object types to always re-export
      - FileGroups
      - DatabaseScopedConfigurations
      - XmlSchemaCollections
      - FullTextCatalogs
```

---

## Implementation Phases

### Phase 1: Metadata & Object List Foundation (5 hours)

- [ ] Add `_export_metadata.json` generation to Export script
- [ ] Add `_object_list.json` generation with objectId tracking
- [ ] Include export timestamp, server time in metadata
- [ ] Add metadata/object list reading functions
- [ ] Unit tests for generation/reading

### Phase 2: Date-Based Filtering (6 hours)

- [ ] Add `-ModifiedSince` parameter
- [ ] Create `Get-ModifiedObjects` function querying sys.objects
- [ ] Filter export to only modified objects
- [ ] Handle objects without modify_date (always export or skip with warning)
- [ ] Validate `groupBy: single` when incremental mode used
- [ ] Integration tests

### Phase 3: Previous Export Reference (5 hours)

- [ ] Add `-DeltaFrom` parameter
- [ ] Read metadata and object list from previous export
- [ ] Detect dropped objects (compare object lists by objectId)
- [ ] Detect renamed objects (same objectId, different name)
- [ ] Report dropped/renamed objects in output
- [ ] Integration tests

### Phase 4: Auto-Detection (2 hours)

- [ ] Add `-DeltaFromLatest` switch
- [ ] Scan OutputPath for latest export with valid metadata
- [ ] Use that export as delta reference
- [ ] Tests

### Phase 5: Merge Utility (Deferred)

- Deferred until core incremental functionality is stable
- Only viable for `groupBy: single` exports
- See "Merge Utility" section for future design

**Total Estimated Time**: 18 hours (excluding deferred merge utility)

---

## Conclusion

Incremental export is **feasible** with the following caveats:

| Capability | Feasibility | Notes |
|------------|-------------|-------|
| Detect modified objects | HIGH | sys.objects.modify_date |
| Detect dropped objects | HIGH | Via _object_list.json comparison |
| Detect renamed objects | HIGH | Via objectId tracking in _object_list.json |
| Handle all object types | MEDIUM | Some objects lack modify_date (always export) |
| Merge exports | LOW | Only works with groupBy: single; deferred |

### Key Constraints

1. **Requires `groupBy: single`**: Incremental export only works reliably when each object has its own file
2. **Object list required**: Every export generates `_object_list.json` to enable delete/rename detection
3. **Merge utility deferred**: Focus on core incremental functionality first

**Recommendation**: Implement Phase 1-4 (metadata, object list, date-based, path-based incremental). Defer merge utility until the workflow is proven.

---

## References

- [sys.objects (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-objects-transact-sql)
- [sys.database_principals (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-database-principals-transact-sql)
- [sys.triggers (Transact-SQL)](https://learn.microsoft.com/en-us/sql/relational-databases/system-catalog-views/sys-triggers-transact-sql)
