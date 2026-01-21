# Performance Analysis: GroupBy Modes Comparison

## Test Environment

- **Date**: January 21, 2026
- **SQL Server**: SQL Server 2022 (Linux container)
- **PowerShell**: 7.x
- **Database**: PerfTestDb (500 tables, 100 views, 500 procedures, 100 functions, 100 triggers, 2000 indexes, 50,000 rows)

## Baseline Comparison

### Previous Baseline (v1.4.x)

| Metric | Value |
|--------|-------|
| Export Duration | 207.86s |
| Files Generated | 2,897 |
| Import Duration | 104.23s |
| Total Round-Trip | 312.09s |

### New Results (v1.5.0 with GroupBy Fix)

| GroupBy Mode | Export (s) | Files | Import (s) | Total (s) |
|--------------|------------|-------|------------|-----------|
| **single** | 231.33 | 2,900 | 22.62 | 253.95 |
| **schema** | 224.78 | 601 | 14.34 | 239.13 |
| **all** | 215.42 | 529 | 11.29 | 226.72 |

## Analysis

### Export Performance

| Mode | Duration | Change vs Baseline | Change vs Single |
|------|----------|-------------------|------------------|
| single | 231.33s | +11% slower | - |
| schema | 224.78s | +8% slower | 3% faster |
| all | 215.42s | +4% slower | 7% faster |

**Observation**: Export times are slightly slower than baseline, likely due to the AppendToFile logic added to fix the multi-object file bug. The overhead of setting `AppendToFile = $true` after each object is minimal but measurable.

### Import Performance

| Mode | Duration | Change vs Baseline | Change vs Single |
|------|----------|-------------------|------------------|
| single | 22.62s | **78% faster** | - |
| schema | 14.34s | **86% faster** | 37% faster |
| all | 11.29s | **89% faster** | 50% faster |

**Major Finding**: Import times have dramatically improved across all modes. This is due to:
1. Persistent SMO connection (single connection for all scripts)
2. Direct SQL queries instead of SMO metadata enumeration
3. Fewer files to process (schema and all modes)

### Total Round-Trip Time

| Mode | Duration | Change vs Baseline |
|------|----------|-------------------|
| single | 253.95s | **19% faster** |
| schema | 239.13s | **23% faster** |
| all | 226.72s | **27% faster** |

### File Count Impact

| Mode | Files | Reduction vs Single |
|------|-------|---------------------|
| single | 2,900 | - |
| schema | 601 | 79% fewer files |
| all | 529 | 82% fewer files |

## Recommendations

### When to Use Each Mode

| Mode | Best For | Trade-offs |
|------|----------|------------|
| **single** | Git workflows, individual object tracking | More files, slightly slower import |
| **schema** | Team-based development (schema-per-team) | Balance of organization and speed |
| **all** | CI/CD pipelines, fast deployments | Fastest import, harder to diff individual changes |

### Performance Tips

1. **For fastest deployments**: Use `groupBy: all` - 50% faster import than single mode
2. **For best Git experience**: Use `groupBy: single` (default) - individual file changes are easy to track
3. **For team-based development**: Use `groupBy: schema` - good balance of both

## Bug Fix Included

This test validates the critical **AppendToFile bug fix** in v1.5.0:

- **Bug**: When using `schema` or `all` grouping modes, only the last object was saved to each file
- **Cause**: SMO's `EnumScript()` overwrites the file by default (`AppendToFile = $false`)
- **Fix**: Set `AppendToFile = $true` after the first object is written to enable appending
- **Impact**: All 39 grouping code sections were fixed

## Test Commands

```powershell
# Run performance tests with different groupBy modes
cd tests
.\run-perf-test.ps1 -ExportConfigYaml .\test-groupby-single.yml
.\run-perf-test.ps1 -ExportConfigYaml .\test-groupby-schema.yml
.\run-perf-test.ps1 -ExportConfigYaml .\test-groupby-all.yml
```

## Conclusion

The v1.5.0 release provides significant performance improvements for import operations (78-89% faster) while fixing a critical bug that prevented `schema` and `all` grouping modes from working correctly. The choice of grouping mode now offers a meaningful trade-off between Git-friendliness and deployment speed.
