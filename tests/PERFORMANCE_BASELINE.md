# Performance Baseline Metrics

## Overview

This document records baseline performance metrics for `Export-SqlServerSchema.ps1` before optimization work begins. These metrics serve as the comparison point for measuring improvement from performance optimizations.

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

### Time Distribution

```
Schema Export:  53.01 sec (86.6%)  ████████████████████░░░
Data Export:     8.11 sec (13.2%)  ███░░░░░░░░░░░░░░░░░░░░
Connection:      0.01 sec ( 0.0%)  ░░░░░░░░░░░░░░░░░░░░░░░
```

### Key Observations

1. **Schema export dominates** - 87% of total time spent exporting schema objects
2. **Object-by-object processing** - Each of 252 objects processed individually
3. **Average time per object** - ~210ms per schema object (including network round-trips)
4. **Data export relatively fast** - 8 seconds for 50,000 rows across 50 tables

## Identified Bottlenecks

Based on code analysis, these are the primary performance issues:

| Priority | Issue | Impact |
|----------|-------|--------|
| CRITICAL | Object-by-object scripting | Thousands of network round-trips |
| CRITICAL | SMO lazy loading (N+1 queries) | Extra queries per property access |
| CRITICAL | Per-table COUNT queries | 50 separate queries for row counts |
| HIGH | Multiple collection passes | Redundant iteration over tables |
| HIGH | No parallelism | Single-threaded processing |
| MEDIUM | Verbose console output | I/O overhead per object |

## Optimization Plan

| Phase | Optimization | Expected Impact |
|-------|--------------|-----------------|
| 1 | Single-pass row count query | Minor (data export only) |
| 2 | SMO prefetch with SetDefaultInitFields | Moderate |
| 3 | Batch scripting with EnumScript | Major |
| 4 | Reduce console output frequency | Minor |
| 5 | Parallel processing | Major (deferred - higher risk) |

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

## Files

- `baseline-metrics.json` - Raw metrics data in JSON format
- `create-perf-test-db.sql` - Script to create the test database
