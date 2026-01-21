# Performance Test Database Documentation

## Overview

The `create-perf-test-db.sql` script creates a large-scale performance test database designed to stress-test the Export-SqlServerSchema and Import-SqlServerSchema scripts with realistic large database scenarios.

## Database Size

The performance test database has been scaled up **100x from the original version** to better measure performance characteristics:

### Object Counts

| Object Type | Count | Per Schema | Notes |
|------------|-------|------------|-------|
| Schemas | 100 | N/A | Schema1 through Schema100 |
| Tables | 5,000 | 50 | Each with 1,000 rows of test data |
| Indexes | 15,000 | 150 | 3 per table (PK, unique, filtered) |
| Stored Procedures | 5,000 | 50 | Various types: SELECT, UPDATE, INSERT, aggregation, complex queries |
| Views | 2,000 | 20 | Aggregation, filtered, calculated, TOP N views |
| Scalar Functions | 2,000 | 20 | Calculations, conversions, categorizations |
| Table-Valued Functions | 1,000 | 10 | Inline TVFs with filtering and aggregation |
| Triggers | 1,000 | 10 | UPDATE, INSERT, DELETE (soft delete) triggers |
| Synonyms | 500 | 5 | Aliases for tables |
| User-Defined Types | 200 | 2 | NVARCHAR and DECIMAL types |
| Database Roles | 10 | N/A | AppRole1 through AppRole10 |
| Database Users | 20 | N/A | TestUser1 through TestUser20 |
| Total Data Rows | 5,000,000 | N/A | 1,000 rows per table |

### Data Volume

- **5 million rows** of randomly generated test data
- Approximately **500-750 MB** of data (varies by SQL Server storage)
- Each table contains realistic data:
  - Unique codes with schema/table identifiers
  - Descriptive names and descriptions
  - Numeric amounts and quantities
  - Categories (A-E) and statuses (Active/Pending/Inactive)
  - Dates, priorities, ratings, and assignments

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
   # This will take several minutes to complete
   Invoke-Sqlcmd -ServerInstance localhost -Username sa -Password 'Test@1234' -InputFile "create-perf-test-db.sql" -QueryTimeout 3600
   ```

   **Expected runtime:** 5-15 minutes depending on hardware
   - Table creation: 1-3 minutes
   - Data population: 3-10 minutes
   - Programmability objects: 1-2 minutes

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
5. **Complex procedures** - Window functions, CTEs, ranking

### Views

Four different view patterns:
1. **Aggregation views** - COUNT, SUM, AVG, MAX with GROUP BY
2. **Filtered views** - WHERE clauses on IsActive and Status
3. **Calculated views** - CASE expressions, DATEDIFF, computed columns
4. **TOP N views** - Ordered by Amount DESC

### Functions

**Scalar Functions** (4 patterns):
1. Multiplication calculations
2. Average calculations
3. Date difference calculations
4. Categorization (Premium/Standard/Basic)

**Table-Valued Functions** (3 patterns):
1. Top N items ordered by Amount
2. Filtered by Category and MinAmount
3. Aggregation grouped by Category

### Triggers

Three trigger types:
1. **AFTER UPDATE** - Sets ModifiedDate timestamp
2. **AFTER INSERT** - Validates Amount is not negative
3. **INSTEAD OF DELETE** - Soft delete by setting IsActive = 0

### Security

**Roles:** 10 application roles (AppRole1-AppRole10)
**Users:** 20 test users (TestUser1-TestUser20) without logins
**Permissions:**
- Each role has SELECT and EXECUTE on 10 schemas
- Each user is assigned to one role (round-robin)

## Performance Characteristics

### Expected Performance Metrics

Based on typical hardware (4 CPU, 8GB RAM):

| Operation | Time | Rate |
|-----------|------|------|
| Table Creation | 1-3 min | ~50-150 tables/sec |
| Data Population | 3-10 min | ~10K-20K rows/sec |
| Proc/View Creation | 1-2 min | ~100-200 objects/sec |
| Export (no data) | 2-5 min | ~1000-2000 objects/min |
| Export (with data) | 5-15 min | Varies by data size |
| Import (no data) | 2-5 min | ~1000-2000 objects/min |
| Import (with data) | 5-15 min | Varies by data size |

### Scalability Testing

To test even larger databases, modify the script constants:

```sql
-- In create-perf-test-db.sql, change:
WHILE @schemaNum <= 100  -- Change to 200 for 2x, 500 for 5x, etc.
WHILE @tableNum <= 50    -- Change to 100 for 2x per schema
@RowsPerTable = 1000     -- Change to 2000 for 2x rows per table
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

### Why 100x Increase?

The original performance test (10 schemas, 50 tables, 50K rows) was too small to:
- Measure meaningful performance differences in optimization efforts
- Test behavior with large object counts (export file organization, memory usage)
- Validate performance at realistic enterprise database scales

The 100x increase (100 schemas, 5000 tables, 5M rows) provides:
- **Realistic scale**: Many enterprise databases have thousands of tables
- **Performance visibility**: Changes that improve performance by 10% are measurable
- **Stress testing**: Identifies memory limits, timeouts, and scalability issues
- **CI/CD validation**: Can verify that performance doesn't regress between releases

### Object Variety

The test includes various object patterns to ensure the export/import scripts handle:
- Simple and complex SELECT queries
- INSERT/UPDATE/DELETE operations
- Window functions and CTEs
- Aggregations and grouping
- Triggers with business logic
- Filtered indexes for performance
- Security principals and permissions

This variety ensures comprehensive test coverage while maintaining script simplicity.

## Comparison: Original vs Enhanced

| Metric | Original | Enhanced | Multiplier |
|--------|----------|----------|------------|
| Schemas | 10 | 100 | 10x |
| Tables | 50 | 5,000 | 100x |
| Procedures | 50 | 5,000 | 100x |
| Views | 20 | 2,000 | 100x |
| Functions | 30 | 3,000 | 100x |
| Triggers | 0 | 1,000 | NEW |
| Synonyms | 0 | 500 | NEW |
| Types | 0 | 200 | NEW |
| Security | 0 | 30 | NEW |
| Data Rows | 50,000 | 5,000,000 | 100x |
| Est. Runtime | 30 sec | 5-15 min | 10-30x |

## Future Enhancements

Potential additions for even more comprehensive testing:
- Foreign key constraints between tables
- Partitioned tables with partition schemes
- Full-text indexes and catalogs
- Computed columns (persisted and non-persisted)
- Check constraints with complex expressions
- Defaults and rules
- XML indexes and XML schema collections
- Spatial indexes and geography/geometry data
- Encrypted columns (Always Encrypted)
- Temporal tables (system-versioned)
