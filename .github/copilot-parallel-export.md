# Parallel Export Implementation Instructions

This file provides context for AI assistants implementing the parallel export feature.

## Current Task

Implement parallel export processing for `Export-SqlServerSchema.ps1` as described in the design documents.

## Key Documents

1. **Design Overview**: `docs/PARALLEL_EXPORT_DESIGN.md` - Architecture, data structures, decisions
2. **Implementation Guide**: `docs/PARALLEL_EXPORT_IMPLEMENTATION.md` - Step-by-step tasks with code

## Implementation Order

Follow the phases in order:

1. **Phase 1**: Configuration & Parameters (Tasks 1.1-1.4)
2. **Phase 2**: Work Item Infrastructure (Tasks 2.1-2.4)  
3. **Phase 3**: Worker Implementation (Tasks 3.1-3.4)
4. **Phase 4**: Progress & Results (Tasks 4.1-4.3)
5. **Phase 5**: Integration (Tasks 5.1-5.4)
6. **Phase 6**: Testing (Tasks 6.1-6.3)

## Critical Constraints

### SMO Objects Cannot Cross Runspaces
- SMO objects are bound to their connection
- Work items contain **identifiers only** (schema, name)
- Workers re-fetch SMO objects using their own connection

### File Contention Prevention
- One file = one work item (by design)
- No locking needed
- GroupBy mode determines work item bundling

### Non-Parallelizable Objects
Export these sequentially FIRST (before parallel workers start):
- FileGroups (custom StringBuilder, SQLCMD variables)
- DatabaseScopedConfigurations (not SMO scriptable)
- DatabaseScopedCredentials (documentation only)

## Code Style

Follow existing patterns in `Export-SqlServerSchema.ps1`:
- Use `Write-Host` for user output (not `Write-Output`)
- Use `Write-ProgressHeader` for section headers
- Prefix parallel output with `[Parallel]`
- Use `[SUCCESS]`, `[ERROR]`, `[WARNING]` prefixes

## Testing Requirements

1. Parallel export must produce identical output to sequential
2. All groupBy modes (single, schema, all) must work
3. Sequential mode must not regress
4. Integration tests must pass

## Files to Modify

| File | Changes |
|------|---------|
| `Export-SqlServerSchema.ps1` | Add functions, parameters, parallel branch |
| `export-import-config.schema.json` | Add parallel config schema |
| `export-import-config.example.yml` | Add parallel config example |
| `tests/run-integration-test.ps1` | Add parallel mode test |

## Build-ParallelWorkQueue Expansion

The implementation guide shows patterns for Tables, ForeignKeys, Views, StoredProcedures, and Functions. **You must expand this to cover ALL object types** listed in `PARALLEL_EXPORT_DESIGN.md` Object Type Classification section.

Follow the existing patterns in `Export-DatabaseObjects` for each object type's:
- Collection access (`$Database.Tables`, etc.)
- Output directory (`09_Tables_PrimaryKey`, etc.)
- Scripting options
- File naming conventions

## Object Types Requiring Special Handling

| Object Type | Special Handling |
|-------------|------------------|
| ForeignKeys | Script tables with FK options, not FK objects directly |
| Indexes | Nested from tables, script with index-specific options |
| TableTriggers | Nested from tables |
| SecurityPolicies | Custom header before SMO script |
| Data | Use ScriptData option, handle large tables |

## Verification

Before marking complete, verify:
- [ ] `-Parallel` switch works
- [ ] YAML `export.parallel.enabled: true` works
- [ ] Sequential mode unchanged
- [ ] All object types export
- [ ] All groupBy modes work
- [ ] Progress displays correctly
- [ ] Errors are reported
- [ ] Integration tests pass
