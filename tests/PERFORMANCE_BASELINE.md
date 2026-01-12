# Performance Optimization Metrics

## Overview

This document tracks performance metrics for `Export-SqlServerSchema.ps1` across optimization phases. Each phase's results are compared against the baseline to measure improvement.

## Test Environment

| Component | Details |
|-----------|---------|
| SQL Server | SQL Server 2022 (RTM-CU22) in Docker |
| Host | localhost:1433 |
| PowerShell | 7.x |
| SMO | SqlServer module |

## Codebase Version

| Field | Value |
|-------|-------|
| Git Commit | `053665e` |
| Git Branch | `feature/optimize-export` |
| Commit Message | "collect metrics" |
| Test Date | 2026-01-12 |

## Test Database: PerfTestDb

A purpose-built database for performance testing with realistic object counts:

| Object Type | Count |
|-------------|------:|
| Schemas | 10 |
| Tables | 50 |
| Indexes | 150 |
| Stored Procedures | 52 |
| Views | 20 |
| Functions | 30 |
| **Total Data Rows** | **50,000** |

Created using: `tests/create-perf-test-db.sql`

## Baseline Results

### Summary

| Metric | Value |
|--------|------:|
| **Total Duration** | **61.21 sec** |
| Connection Time | 0.01 sec |
| Schema Export | 53.01 sec |
| Data Export | 8.11 sec |
| Files Created | 314 |
| Errors | 0 |

### Key Observations

1. **Schema export dominates** - 87% of total time spent exporting schema objects
2. **Object-by-object processing** - Each of 252 objects processed individually
3. **Average time per object** - ~210ms per schema object (including network round-trips)
4. **Data export relatively fast** - 8 seconds for 50,000 rows across 50 tables

## Identified Bottlenecks

| Priority | Issue | Impact |
|----------|-------|--------|
| CRITICAL | Object-by-object scripting | Thousands of network round-trips |
| CRITICAL | SMO lazy loading (N+1 queries) | Extra queries per property access |
| CRITICAL | Per-table COUNT queries | 50 separate queries for row counts |
| HIGH | Multiple collection passes | Redundant iteration over tables |
| HIGH | No parallelism | Single-threaded processing |
| MEDIUM | Verbose console output | I/O overhead per object |

---

## Performance Comparison

### Summary Table

| Metric | Baseline | Phase 1 | Phase 2 | Phase 3 | Phase 4 |
|--------|----------|---------|---------|---------|---------|
| **Total Duration** | **61.21 sec** | **61.26 sec** | **30.69 sec** | - | - |
| Connection Time | 0.01 sec | 0.01 sec | 0.01 sec | - | - |
| Schema Export | 53.01 sec | 53.06 sec | 22.65 sec | - | - |
| Data Export | 8.11 sec | 8.11 sec | 7.93 sec | - | - |
| Files Created | 314 | 314 | 314 | - | - |
| Errors | 0 | 0 | 0 | - | - |
| **Improvement** | - | **0%** | **-49.9%** | - | - |

### Phase Details

| Phase | Git Commit | Description | Duration | vs Baseline |
|-------|------------|-------------|----------|-------------|
| Baseline | `053665e` | Original code before optimizations | 61.21 sec | - |
| Phase 1 | `053665e` | Single-pass row count via sys.partitions | 61.26 sec | +0.08% |
| Phase 2 | `7b4a4ef` | SMO prefetch with SetDefaultInitFields | 30.69 sec | **-49.9%** |
| Phase 3 | - | Batch scripting with EnumScript | - | - |
| Phase 4 | - | Reduce console output frequency | - | - |

### Phase 1 Analysis

**Change**: Replaced 50 individual `SELECT COUNT(*) FROM table` queries with a single `SELECT ... FROM sys.partitions` query to get all row counts at once.

**Result**: No measurable improvement on localhost testing (+0.08%, within margin of error).

**Explanation**: This optimization eliminates network round-trips for row count queries. On localhost (zero network latency), the benefit is negligible. The optimization will show significant improvement when:
- Exporting over a network connection with latency
- Database has hundreds of tables  
- Each COUNT(*) query would otherwise take 10-50ms round-trip

### Phase 2 Analysis

**Change**: Added `SetDefaultInitFields($type, $true)` for 13 SMO object types immediately after connection. This tells SMO to prefetch ALL properties for these types in bulk when collections are first accessed, instead of lazy-loading each property on demand.

**Result**: **49.9% improvement** - Schema export dropped from 53.01 sec to 22.65 sec.

**Explanation**: By default, SMO uses lazy loading - accessing a property like `Table.IsSystemObject` triggers a separate SQL query. With 50 tables and 100+ indexes, this creates hundreds of extra round-trips. SetDefaultInitFields eliminates this N+1 query problem by fetching all properties in the initial collection query.

**Types prefetched**:
- Table, Column, Index, ForeignKey
- StoredProcedure, View, UserDefinedFunction, Trigger
- Schema, UserDefinedType, UserDefinedTableType
- Synonym, Sequence

---

## How to Reproduce

```powershell
# Start test SQL Server
cd tests
docker-compose up -d

# Wait for SQL Server to start, then create test database
docker cp create-perf-test-db.sql sqlserver-test:/create-perf-test-db.sql
docker exec sqlserver-test /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "Test@1234" -C -i /create-perf-test-db.sql

# Run export with metrics
$cred = New-Object PSCredential -ArgumentList 'sa', (ConvertTo-SecureString 'Test@1234' -AsPlainText -Force)
.\Export-SqlServerSchema.ps1 -Server 'localhost,1433' -Database 'PerfTestDb' -OutputPath '.\DbScripts' -Credential $cred -CollectMetrics -IncludeData
```

## Metrics Files

| File | Description |
|------|-------------|
| `baseline-metrics.json` | Raw baseline metrics (original code) |
| `phase1-metrics.json` | Phase 1 metrics (single-pass row count) |
| `phase2-metrics.json` | Phase 2 metrics (SMO prefetch) |
| `create-perf-test-db.sql` | Script to create PerfTestDb |
