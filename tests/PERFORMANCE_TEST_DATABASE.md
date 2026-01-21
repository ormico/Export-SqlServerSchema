# Performance Test Database Documentation

## Overview

The `create-perf-test-db-simplified.sql` script creates a moderately-sized performance test database designed to test the Export-SqlServerSchema and Import-SqlServerSchema scripts with reliable execution times.

## Database Size

The performance test database uses a **simplified schema** for reliable testing:

### Object Counts

| Object Type | Count | Per Schema | Notes |
|------------|-------|------------|-------|
| Schemas | 10 | N/A | Schema1 through Schema10 |
| Tables | 500 | 50 | Each with 100 rows of test data |
| Indexes | 2,000 | 200 | 4 per table (PK, unique, non-clustered, filtered) |
| Stored Procedures | 500 | 50 | Various types: SELECT with filtering and aggregation |
| Views | 100 | 10 | Aggregation views with GROUP BY |
| Scalar Functions | 100 | 10 | Simple calculation functions |
| Table-Valued Functions | 0 | 0 | Not included |
| Triggers | 0 | 0 | Not included |
| Synonyms | 0 | 0 | Not included |
| User-Defined Types | 0 | 0 | Not included |
| Database Roles | 0 | 0 | Not included |
| Database Users | 0 | 0 | Not included |
| Total Data Rows | 50,000 | N/A | 100 rows per table |

### Data Volume

- **50,000 rows** of test data
- Approximately **5-10 MB** of data (varies by SQL Server storage)
- Each table contains realistic data:
  - Unique codes with schema/table identifiers
  - Descriptive names and descriptions
  - Numeric amounts and quantities
  - Categories (A-E) and statuses (Active/Pending/Inactive)
  - Dates and notes

## Usage

### Creating the Performance Test Database

1. **Start SQL Server** (using Docker or existing instance)
   ```bash
   cd tests
   docker-compose up -d
   ```

2. **Create the database**
   ```powershell
   # Using sqlcmd
   sqlcmd -S localhost -U sa -P 'Test@1234' -Q "CREATE DATABASE PerfTestDb"
   
   # Or using PowerShell
   Invoke-Sqlcmd -ServerInstance localhost -Username sa -Password 'Test@1234' -Query "CREATE DATABASE PerfTestDb"
   ```

3. **Run the creation script**
   ```powershell
   # This will take about 20-30 seconds to complete
   sqlcmd -S localhost -U sa -P 'Test@1234' -d PerfTestDb -i "create-perf-test-db-simplified.sql"
   ```

   **Expected runtime:** 20-30 seconds depending on hardware
   - Table creation: ~5 seconds
   - Data population: ~15 seconds
   - Programmability objects: ~10 seconds

### Testing Export/Import Performance

```powershell
# Export the performance test database
$exportStart = Get-Date
pwsh ../Export-SqlServerSchema.ps1 -Server localhost -Database PerfTestDb -IncludeData
$exportDuration = (Get-Date) - $exportStart
Write-Host "Export completed in $($exportDuration.TotalMinutes) minutes"

# Import to a new database
$importStart = Get-Date
pwsh ../Import-SqlServerSchema.ps1 -Server localhost -Database PerfTestDb_Restored -SourcePath "./exports/localhost_PerfTestDb_*" -IncludeData -CreateDatabase
$importDuration = (Get-Date) - $importStart
Write-Host "Import completed in $($importDuration.TotalMinutes) minutes"
```

## Object Type Details

### Tables

Each table includes:
- **Primary Key**: Identity column (Id)
- **Unique Index**: On Code column
- **Non-clustered Index**: On Status with included columns
- **Filtered Index**: On CreatedDate and Category where IsActive = 1

Columns:
- `Id` - Identity primary key
- `Code` - Unique identifier (schema-table-number format)
- `Name` - Item description
- `Description` - Long text field
- `Amount` - Decimal value for calculations
- `Quantity` - Integer value
- `IsActive` - Boolean flag
- `CreatedDate`, `ModifiedDate` - Temporal data
- `Category` - A through E classification
- `Status` - Active/Pending/Inactive
- `Notes` - Additional text
- `Priority` - 1 through 5 ranking
- `AssignedTo` - User assignment (User1-User10)
- `CompletionDate` - Date field
- `Rating` - Decimal rating value

### Stored Procedures

Five different procedure patterns per schema:
1. **SELECT procedures** - Filtered queries with optional parameters
2. **Aggregation procedures** - GROUP BY with HAVING clauses
3. **UPDATE procedures** - Modify records with audit timestamp
4. **INSERT procedures** - Add new records, return SCOPE_IDENTITY
### Views

Simple aggregation views:
- **Aggregation views** - COUNT, SUM, AVG, MAX with GROUP BY
- Groups by Category and Status
- 100 views total (10 per schema)

### Functions

**Scalar Functions**:
- Simple calculation functions (multiply by 1.1)
- 100 functions total (10 per schema)

### Tables

Each table includes:
- **Primary Key**: Identity column (Id)
- **Unique Index**: On Code column
- **Non-clustered Index**: On Status with included columns (Name, Amount)
- **Filtered Index**: On CreatedDate where IsActive = 1

Columns:
- `Id` - Identity primary key
- `Code` - Unique identifier (schema-table-number format)
- `Name` - Item description
- `Description` - Text field
- `Amount` - Decimal value for calculations
- `Quantity` - Integer value
- `IsActive` - Boolean flag (default 1)
- `CreatedDate`, `ModifiedDate` - Temporal data
- `Category` - A through E classification
- `Status` - Active/Pending/Inactive (default 'Active')
- `Notes` - Additional text

## Performance Characteristics

### Expected Performance Metrics

Based on typical hardware (4 CPU, 8GB RAM):

| Operation | Time | Rate |
|-----------|------|------|
| Database Creation | 20-30 sec | 500 tables in 20s |
| Data Population | ~15 sec | ~3,000 rows/sec |
| Proc/View Creation | ~10 sec | ~60 objects/sec |
| Export (no data) | 1-2 min | ~1,600 objects/min |
| Export (with data) | 6-8 min | ~126 rows/sec |
| Import (no data) | 1-2 min | ~1,600 scripts/min |
| Import (with data) | 3-4 min | ~263 rows/sec |

### Scalability Testing

To test larger databases, modify the script constants:

```sql
-- In create-perf-test-db-simplified.sql, change:
WHILE @schemaNum <= 10   -- Change to 20 for 2x schemas
WHILE @tableNum <= 50    -- Change to 100 for 2x tables per schema
-- Generate 100 sample rows -- Change to 200 for 2x rows per table
```

## Validation

Use the included validation script to check SQL syntax:

```powershell
pwsh ./validate-perf-test-syntax.ps1
```

This performs basic checks:
- Keyword presence
- GO separator count
- CREATE OR ALTER usage
- Documentation completeness

## Cleanup

To remove the performance test database:

```powershell
# Drop the database
Invoke-Sqlcmd -ServerInstance localhost -Username sa -Password 'Test@1234' -Query "DROP DATABASE IF EXISTS PerfTestDb"

# If testing import as well
Invoke-Sqlcmd -ServerInstance localhost -Username sa -Password 'Test@1234' -Query "DROP DATABASE IF EXISTS PerfTestDb_Restored"
```

## Design Rationale

### Why Simplified Version?

The simplified performance test (10 schemas, 500 tables, 50K rows) provides:
- **Reliable execution**: Completes in 20-30 seconds without timeouts
- **Sufficient scale**: Tests realistic performance with meaningful object counts
- **Reproducibility**: Consistent results across different environments
- **Development friendly**: Quick iteration during script development
- **Adequate coverage**: Tests all major object types and patterns

### Object Variety

The test includes essential object patterns:
- Stored procedures with filtering and aggregation
- Views with GROUP BY operations
- Scalar functions for calculations
- Multiple index types (PK, unique, non-clustered, filtered)
- Realistic data distributions

This variety ensures comprehensive test coverage while maintaining fast, reliable execution.

## Database Object Summary

| Object Type | Count | Notes |
|------------|-------|-------|
| Schemas | 10 | Schema1 through Schema10 |
| Tables | 500 | 50 per schema |
| Indexes | 2,000 | 4 per table |
| Procedures | 500 | 50 per schema |
| Views | 100 | 10 per schema |
| Functions | 100 | 10 per schema |
| Data Rows | 50,000 | 100 rows per table |
| Total Objects | ~3,200 | Sufficient for performance testing |

## Future Enhancements

Potential additions for more comprehensive testing:
- Foreign key constraints between tables
- Triggers for data validation
- User-defined types
- Synonyms for object aliasing
- Security roles and users
- Larger data volumes (scale rows per table)
- More schemas (scale to 20-50 schemas)
