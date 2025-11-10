# Missing Database Objects - Analysis & Recommendations

**Date**: November 9, 2025  
**Version**: Export-SqlServerSchema v1.0

## Executive Summary

This document analyzes SQL Server database objects not currently exported by the schema export tool and provides recommendations for handling each type during database migration, development, and deployment scenarios.

## Missing Objects Overview

| Object Type | SQL Version | Common Usage | Scriptable | Priority | Recommendation |
|------------|-------------|--------------|------------|----------|----------------|
| **DatabaseScopedConfigurations** | 2016+ | High | Yes | **HIGH** | **ADD** - Controls important DB settings like MAXDOP, query optimizer, parameter sniffing |
| **FileGroups** | All | Medium-High | Yes | **HIGH** | **ADD** - Critical for proper data placement, partitioning, and performance optimization |
| **SecurityPolicies** | 2016+ | Medium | Yes | **MEDIUM** | **ADD** - Row-Level Security is increasingly common in multi-tenant apps |
| **SearchPropertyLists** | 2008+ | Low-Medium | Yes | **MEDIUM** | **ADD** - Required if using custom full-text search properties |
| **DatabaseScopedCredentials** | 2016+ | Medium | Yes | **MEDIUM** | **ADD** - Needed for PolyBase, managed backups, external data sources |
| **ExternalDataSources** | 2016+ | Medium | Yes | **MEDIUM** | **ADD** - Common with PolyBase, Elastic Query, data virtualization |
| **ExternalFileFormats** | 2016+ | Medium | Yes | **LOW** | **ADD IF** - Only if ExternalDataSources exist |
| **PlanGuides** | 2005+ | Low | Yes | **LOW** | **OPTIONAL** - Typically environment-specific, rarely needed |
| **ColumnMasterKeys** | 2016+ | Low | Partial | **LOW** | **SKIP** - Always Encrypted requires out-of-band key management |
| **ColumnEncryptionKeys** | 2016+ | Low | Partial | **LOW** | **SKIP** - Depends on ColumnMasterKeys, complex certificate handling |
| **ExternalLibraries** | 2017+ | Low | Yes | **LOW** | **OPTIONAL** - Only for R/Python ML Services users |
| **ExternalLanguages** | 2019+ | Very Low | Yes | **LOW** | **OPTIONAL** - Java/custom language extensions, rare |
| **ExternalStreams** | Edge Only | Very Low | Yes | **SKIP** | **SKIP** - Azure SQL Edge only, not standard SQL Server |
| **ExternalStreamingJobs** | Edge Only | Very Low | Yes | **SKIP** | **SKIP** - Azure SQL Edge only, not standard SQL Server |
| **WorkloadManagementWorkloadClassifiers** | DW Only | Very Low | Yes | **SKIP** | **SKIP** - Azure Synapse/SQL DW specific |
| **WorkloadManagementWorkloadGroups** | DW Only | Very Low | Yes | **SKIP** | **SKIP** - Azure Synapse/SQL DW specific |

---

## Physical Storage Objects - Deep Dive

### FileGroups & Data Files

**What they are:**
- FileGroups are logical containers for data files
- Control physical storage location and I/O distribution
- Critical for table partitioning, performance optimization, and backup strategies

**Migration & Deployment Strategy:**

#### Production Migration (Same infrastructure scale)
```
Recommendation: INCLUDE with modifications
- Export FileGroup structure
- Document file paths but DON'T hardcode
- Use variables/parameters for file locations
- Preserve FileGroup names for object assignments
```

**Why?**
- Table and index placement depends on FileGroup names
- Partitioned tables require specific FileGroups
- Breaking these relationships causes errors

**Example Scenario:**
```sql
-- Source has:
CREATE TABLE Orders (...) ON [FG_CURRENT_YEAR]
CREATE INDEX IX_Orders ON Orders (...) ON [FG_HISTORICAL]

-- If FileGroups aren't created, deployment fails
```

#### Developer Workstation Copy
```
Recommendation: EXCLUDE or SIMPLIFY
- Use default PRIMARY FileGroup only
- Simplifies local development
- Reduces disk space requirements
- Avoids path configuration issues
```

**Implementation:**
- Provide `-IncludeFileGroups` switch (default: OFF)
- Auto-remap objects to PRIMARY when FileGroups excluded
- Document original FileGroup assignments in comments

#### CI/CD / Test Environments
```
Recommendation: CONDITIONAL
- Include FileGroups if testing partition performance
- Exclude for unit/integration tests
- Use environment-specific override files
```

---

### Partition Functions & Schemes

**What they are:**
- Partition Functions: Define how to split data (by date, ID range, etc.)
- Partition Schemes: Map partitions to FileGroups

**Current Export Status:** ALREADY EXPORTED (Added in recent fix)

**Migration & Deployment Strategy:**

#### Production Migration
```
Recommendation: ALWAYS INCLUDE
- Partition logic is core business logic
- Date-based partitioning for time-series data
- Range partitioning for geographic distribution
```

**Why Critical?**
- Query performance depends on partition elimination
- Archive/purge strategies rely on partition switching
- Cannot change easily after data is loaded

**Example:**
```sql
-- Partition by order year - this is application logic, not infrastructure
CREATE PARTITION FUNCTION PF_OrderYear (datetime)
AS RANGE RIGHT FOR VALUES ('2020-01-01', '2021-01-01', '2022-01-01', ...)
```

#### Developer Workstation Copy
```
Recommendation: INCLUDE (simplified)
- Keep partition functions (logic preservation)
- Can map all partitions to PRIMARY FileGroup
- Developers see correct table structure
```

#### CI/CD / Test Environments
```
Recommendation: ALWAYS INCLUDE
- Tests must validate partition logic
- Ensures partition switching works
- Catches boundary condition bugs
```

---

## Configuration Objects - Deep Dive

### Database Scoped Configurations

**What they are:**
- Database-level settings that override server defaults
- Examples: MAXDOP, LEGACY_CARDINALITY_ESTIMATION, PARAMETER_SNIFFING

**Migration & Deployment Strategy:**

#### Production Migration
```
Recommendation: INCLUDE with review
- Export all configurations
- Review before applying (may be environment-specific)
- Document any intentional differences
```

**Common Configurations:**
```sql
-- These affect query behavior and should migrate
ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 8;
ALTER DATABASE SCOPED CONFIGURATION SET QUERY_OPTIMIZER_HOTFIXES = ON;
ALTER DATABASE SCOPED CONFIGURATION SET PARAMETER_SNIFFING = ON;
```

#### Developer Workstation Copy
```
Recommendation: EXCLUDE or USE DEFAULTS
- Developer machines have different hardware
- MAXDOP=8 on 4-core laptop causes issues
- Let SQL Server auto-configure
```

#### CI/CD / Test Environments
```
Recommendation: MATCH PRODUCTION
- Testing should use production settings
- Catches performance issues early
- Validates optimizer behavior
```

---

### Security Policies (Row-Level Security)

**What they are:**
- Filters that automatically restrict row access
- Predicate functions applied to all SELECT/UPDATE/DELETE
- Multi-tenancy without application changes

**Migration & Deployment Strategy:**

#### Production Migration
```
Recommendation: ALWAYS INCLUDE
- Core security requirement
- Data access compliance (GDPR, HIPAA, etc.)
- Business logic embedded in database
```

**Example:**
```sql
-- Ensures users only see their tenant's data
CREATE SECURITY POLICY CustomerSecurityPolicy
    ADD FILTER PREDICATE dbo.fn_SecurityPredicate(TenantId)
    ON dbo.Orders
WITH (STATE = ON);
```

#### Developer Workstation Copy
```
Recommendation: INCLUDE but DISABLE
- Developers need to see all data for testing
- Export policy but set STATE = OFF
- Document that it's disabled for dev
```

#### CI/CD / Test Environments
```
Recommendation: INCLUDE and ENABLE
- Security tests must validate RLS
- Integration tests ensure correct filtering
- Performance tests check RLS overhead
```

---

### Database Scoped Credentials

**What they are:**
- Credentials for accessing external resources
- Used by PolyBase, Managed Backup, External Data Sources
- Stored securely within database

**Migration & Deployment Strategy:**

#### Production Migration
```
Recommendation: EXPORT STRUCTURE, NOT SECRETS
- Export CREATE CREDENTIAL statement
- Replace SECRET with placeholder
- Document credential requirements
- Use Azure Key Vault or secret management
```

**Safe Export:**
```sql
-- Export this:
CREATE DATABASE SCOPED CREDENTIAL AzureBlobCredential
WITH IDENTITY = 'SHARED ACCESS SIGNATURE',
SECRET = '<PLACEHOLDER - See Key Vault: prod-blob-sas>';
```

#### Developer Workstation Copy
```
Recommendation: USE DEV CREDENTIALS
- Separate dev storage accounts
- Different SAS tokens with limited permissions
- Document credential setup in README
```

#### CI/CD / Test Environments
```
Recommendation: INJECT FROM SECRET STORE
- CI/CD pipeline injects test credentials
- Separate test storage/resources
- Automated rotation without code changes
```

---

## External Data Objects

### External Data Sources & File Formats

**What they are:**
- Connections to external data (Azure Blob, Hadoop, other SQL Servers)
- Used by PolyBase, OPENROWSET, Elastic Query

**Migration & Deployment Strategy:**

#### Production Migration
```
Recommendation: EXPORT WITH PLACEHOLDERS
- Structure is application logic
- Connection strings are environment-specific
- Use configuration tokens
```

**Example:**
```sql
-- Export with parameters
CREATE EXTERNAL DATA SOURCE AzureDataLake
WITH (
    TYPE = BLOB_STORAGE,
    LOCATION = '{{AZURE_DATALAKE_URL}}',  -- Token to replace
    CREDENTIAL = AzureBlobCredential
);
```

#### Developer Workstation Copy
```
Recommendation: MOCK or SKIP
- Developers may not have access to external data
- Provide sample data instead
- Document external dependencies
```

#### CI/CD / Test Environments
```
Recommendation: POINT TO TEST RESOURCES
- Use test storage accounts
- Smaller datasets for faster tests
- Isolated from production data
```

---

## Priority Implementation Tiers

### **Tier 1 - Core Features (Implement Now)**

1. **FileGroups & LogFiles**
   - Add export capability
   - Include `-IncludeFileGroups` switch (default: OFF for dev, ON for prod)
   - Generate path-parameterized scripts
   - Document FileGroup-to-object mappings

2. **DatabaseScopedConfigurations**
   - Always export
   - Add comment warnings for environment-specific settings
   - Include review checklist in deployment README

### **Tier 2 - Modern Features (Next Phase)**

3. **SecurityPolicies** - RLS is becoming standard
4. **DatabaseScopedCredentials** - Handle as templates with placeholders
5. **ExternalDataSources** - Export structure with tokenized URLs
6. **ExternalFileFormats** - Dependent on ExternalDataSources
7. **SearchPropertyLists** - For advanced full-text search users

### **Tier 3 - Optional (Future)**

8. **PlanGuides** - Export with warning that they're environment-specific
9. **ExternalLibraries** - For ML Services users only
10. **ExternalLanguages** - Very rare, low priority

### **Tier 4 - Skip**

11. **Always Encrypted Objects** - Require certificate management, too complex
12. **Azure SQL Edge Objects** - Not standard SQL Server
13. **Synapse Analytics Objects** - Different product

---

## Best Practices Summary

### For Production Migrations
- [INCLUDE] Include: Partitions, SecurityPolicies, core configurations
- [PARAMETERIZE] Parameterize: FileGroup paths, connection strings, credentials
- [DOCUMENT] Document: Any environment-specific settings
- [REVIEW] Review: DatabaseScopedConfigurations before applying

### For Developer Copies
- [INCLUDE] Include: All logical objects (tables, views, procedures, partitions)
- [EXCLUDE] Exclude: FileGroups (use PRIMARY), external connections
- [DISABLE] Disable: SecurityPolicies (for full data access)
- [SIMPLIFY] Simplify: Use server defaults for configurations

### For CI/CD Environments
- [INCLUDE] Include: Everything that affects behavior
- [INJECT] Inject: Credentials from secret management
- [MATCH] Match: Production configurations for accurate testing
- [MOCK] Mock: External data sources with test data

---

## Recommended Tool Enhancements

### New Command-Line Switches

```powershell
# Export everything (production migration)
.\Export-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -IncludeFileGroups `
    -IncludeConfigurations `
    -IncludeSecurityPolicies `
    -ParameterizeSecrets

# Export for developer (simplified)
.\Export-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -DeveloperMode `
    # Automatically: no FileGroups, disabled RLS, simple configs

# Export for CI/CD (test environment)
.\Export-SqlServerSchema.ps1 -Server prod -Database MyDb `
    -TestEnvironmentMode `
    # Includes structure, uses token replacement
```

### Configuration File Approach

```json
{
  "exportProfile": "production",
  "includeFileGroups": true,
  "parameterizeFileGroupPaths": true,
  "includeSecurityPolicies": true,
  "includeDatabaseScopedConfigurations": true,
  "credentialHandling": "template",
  "externalDataSourceHandling": "tokenize"
}
```

---

## Conclusion

The current export tool covers all essential logical database objects. The missing objects fall into three categories:

1. **Physical/Infrastructure** (FileGroups) - Should be parameterized and optional
2. **Configuration** (DatabaseScopedConfigurations) - Should be exported with review warnings
3. **Security & External** (Credentials, Data Sources) - Should be templated with placeholders

**Next Steps:**
1. Implement Tier 1 features (FileGroups, DatabaseScopedConfigurations)
2. Add export profiles (Production, Developer, CI/CD)
3. Implement secret parameterization for Tier 2
4. Create comprehensive deployment documentation

This approach balances completeness with practicality, ensuring the tool works for all migration scenarios while avoiding hard-coded environment-specific values.


