---
description: Code review checklist for Export-SqlServerSchema. Run this before submitting PRs.
applyTo: "**/*.ps1"
---

# Code Review Skill for Export-SqlServerSchema

## Skill Invocation

**Trigger phrases**: "code review", "review my changes", "check for bugs", "pre-PR check"

**When invoked**, systematically:
1. Identify changed/new `.ps1` files (use `get_changed_files` or ask user)
2. Run grep searches for high-risk patterns
3. Read flagged sections and evaluate against rules below
4. Report findings in the output format specified

---

## Output Format

Report findings as a markdown table:

```markdown
## Code Review Results

| Severity | Category | File:Line | Issue | Suggested Fix |
|----------|----------|-----------|-------|---------------|
| 🔴 HIGH | SQL Injection | Export.ps1:2764 | Unescaped `[$Database]` | Use `Get-EscapedSqlIdentifier` |
| 🟡 MEDIUM | Null Check | test.ps1:343 | `$file.FullName` without null check | Add `if ($file) { ... }` |
| 🟢 LOW | Style | Import.ps1:100 | Missing color on Write-Host | Add `-ForegroundColor` |

### Summary
- 🔴 HIGH: X issues (must fix before merge)
- 🟡 MEDIUM: Y issues (should fix)
- 🟢 LOW: Z issues (consider fixing)
```

---

## Automated Checks (Run These First)

Execute these grep searches to find potential issues:

```powershell
# 1. SQL injection - unescaped identifiers in dynamic SQL
Select-String -Path "*.ps1" -Pattern 'ALTER DATABASE \[\$|\[\$\w+\].*=.*\$' | Where-Object { $_ -notmatch 'EscapedSql' }

# 2. Case-sensitive regex (SQL is case-insensitive)
Select-String -Path "*.ps1" -Pattern '\(\?!PRIMARY|\(\?!FILEGROUP' | Where-Object { $_ -notmatch '\(\?i\)' }

# 3. Potential null reference after Select-Object -First
Select-String -Path "*.ps1" -Pattern 'Select-Object -First 1[\s\S]{0,50}\.\w+Name'

# 4. ExecuteNonQuery without try-catch
Select-String -Path "*.ps1" -Pattern 'ExecuteNonQuery|ExecuteScalar' | Where-Object { $_ -notmatch 'try' }

# 5. Path concatenation instead of Join-Path
Select-String -Path "*.ps1" -Pattern '\$\w+\s*\+\s*[''"][\\/]' | Where-Object { $_ -notmatch 'Join-Path' }
```

---

## Review Rules by Category

### 🔴 HIGH SEVERITY

#### 1. SQL Injection Prevention
**Pattern to find**: `[$VariableName]` in SQL strings without escaping

**Rule**: All dynamic SQL with bracketed identifiers MUST use `Get-EscapedSqlIdentifier`

```powershell
# ❌ VULNERABLE
$sql = "ALTER DATABASE [$Database] SET RECOVERY SIMPLE"
$sql = "DROP TABLE [$Schema].[$Table]"

# ✅ SAFE
$escapedDb = Get-EscapedSqlIdentifier -Name $Database
$sql = "ALTER DATABASE [$escapedDb] SET RECOVERY SIMPLE"
```

**Why**: A database named `Test]; DROP DATABASE master;--` breaks out of brackets.

#### 2. Path Traversal Prevention
**Pattern to find**: Schema/object names used directly in file paths

**Rule**: Use `Get-SafeFileName` for any user-controlled path component

```powershell
# ❌ VULNERABLE
$filePath = Join-Path $OutputDir "$Schema.$ObjectName.sql"

# ✅ SAFE
$safeSchema = Get-SafeFileName -Name $Schema
$safeName = Get-SafeFileName -Name $ObjectName
$filePath = Join-Path $OutputDir "$safeSchema.$safeName.sql"
```

#### 3. SMO Object Lookup - All UDT Collections
**Pattern to find**: `UserDefinedType` lookup using only one collection

**Rule**: Must check all three UDT collections:
- `$Database.UserDefinedTypes` (CLR types)
- `$Database.UserDefinedDataTypes` (alias types)  
- `$Database.UserDefinedTableTypes` (table types)

---

### 🟡 MEDIUM SEVERITY

#### 4. Null/Empty Checks
**Pattern to find**: Property access after `Select-Object -First 1` or collection indexing

**Rule**: Always null-check before accessing properties

```powershell
# ❌ RISKY
$file = Get-ChildItem -Filter "*.sql" | Select-Object -First 1
$content = Get-Content $file.FullName

# ✅ SAFE
$file = Get-ChildItem -Filter "*.sql" | Select-Object -First 1
if ($file) {
    $content = Get-Content $file.FullName
}
```

#### 5. Regex Case Sensitivity
**Pattern to find**: SQL keyword patterns without `(?i)` flag

**Rule**: SQL Server identifiers are case-insensitive; use `(?i)` or `-imatch`

```powershell
# ❌ WRONG - won't match "primary" or "Primary"
$pattern = '(?!PRIMARY\])'

# ✅ CORRECT
$pattern = '(?!(?i)PRIMARY\])'
```

#### 6. Error Handling on Destructive Operations
**Pattern to find**: `ExecuteNonQuery`, `ExecuteScalar`, file writes without try-catch

**Rule**: Wrap destructive operations in try-catch with contextual error messages

```powershell
# ❌ RISKY
$conn.ExecuteNonQuery($sql)

# ✅ SAFE
try {
    $conn.ExecuteNonQuery($sql)
} catch {
    Write-Host "[ERROR] Failed to execute SQL on $Database : $_" -ForegroundColor Red
    throw
}
```

#### 7. Thread Safety in Parallel Code
**Pattern to find**: Shared variables in runspace scriptblocks

**Rule**: Use `[System.Collections.Concurrent.*]` for cross-runspace data
**Rule**: Never share SMO connections across runspaces

---

### 🟢 LOW SEVERITY

#### 8. Output Stream Conventions
**Rule**: Use correct output streams:
- `Write-Host` with color for user feedback
- `Write-Output` for pipeline data
- `Write-Verbose` for diagnostics

**Rule**: Color conventions:
- `[SUCCESS]` = Green
- `[ERROR]` = Red  
- `[WARNING]` = Yellow
- `[INFO]` = Cyan

#### 9. Path Construction
**Rule**: Use `Join-Path` not string concatenation

```powershell
# ❌ WRONG
$path = $baseDir + "\subfolder\file.sql"

# ✅ CORRECT
$path = Join-Path $baseDir "subfolder" "file.sql"
```

#### 10. Configuration Access
**Rule**: Check nested hashtables exist before accessing

```powershell
# ❌ RISKY
$value = $config.import.developerMode

# ✅ SAFE
$value = $false
if ($config -and $config.ContainsKey('import') -and $config.import.ContainsKey('developerMode')) {
    $value = $config.import.developerMode
}
```

---

## Post-Review Actions

After completing the review:

1. **For HIGH severity**: Block merge until fixed
2. **For MEDIUM severity**: Request changes, allow merge with justification
3. **For LOW severity**: Note for author, approve merge

If no issues found, respond:
```markdown
## Code Review Results

✅ **No issues found** - Code passes all automated checks and manual review.

Checked categories:
- SQL injection prevention
- Path traversal prevention  
- Null/empty checks
- Error handling
- Regex patterns
- Thread safety
- Output conventions
```
