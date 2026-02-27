#Requires -Version 7.0

<#
.SYNOPSIS
    Tests removeToPrimary FileGroup strategy handling of partition schemes.

.DESCRIPTION
    Validates that the removeToPrimary FileGroup transformation correctly:
    1. Replaces regular filegroup references with [PRIMARY]
    2. Preserves partition scheme references on tables (ON [SchemeName](Column))
    3. Collapses partition scheme TO clauses to ALL TO ([PRIMARY])
    4. Handles TEXTIMAGE_ON and FILESTREAM_ON correctly

    Does NOT require SQL Server — tests the regex transformations in isolation.

.NOTES
    Issue: #80 - removeToPrimary incorrectly replaces partition schemes with [PRIMARY]
#>

param()

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$script:testsPassed = 0
$script:testsFailed = 0

# ─────────────────────────────────────────────────────────────────────────────
# Helper
# ─────────────────────────────────────────────────────────────────────────────

function Write-TestResult {
    param(
        [string]$TestName,
        [bool]$Passed,
        [string]$Message = ''
    )
    if ($Passed) {
        Write-Host "[SUCCESS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    }
    else {
        Write-Host "[FAILED]  $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "  $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

# Local copy of the removeToPrimary transformation logic from Import-SqlServerSchema.ps1.
# Must stay in sync with the algorithm in the main script (lines ~2488-2512).
function Invoke-RemoveToPrimaryTransform {
    param(
        [string]$Sql
    )

    # 1. Tables/Indexes: Replace ) ON [FileGroup] with ) ON [PRIMARY]
    #    Excludes partition scheme references: ) ON [SchemeName](Column) has ( after ]
    $Sql = $Sql -replace '\)\s*ON\s*\[(?!(?i)PRIMARY\])[^\]]+\](?!\s*\()', ') ON [PRIMARY]'

    # 1b. TEXTIMAGE_ON [FileGroup] -> TEXTIMAGE_ON [PRIMARY]
    $Sql = $Sql -replace 'TEXTIMAGE_ON\s*\[(?!(?i)PRIMARY\])[^\]]+\]', 'TEXTIMAGE_ON [PRIMARY]'

    # 1c. FILESTREAM_ON [FileGroup] -> FILESTREAM_ON [PRIMARY]
    $Sql = $Sql -replace 'FILESTREAM_ON\s*\[(?!(?i)PRIMARY\])[^\]]+\]', 'FILESTREAM_ON [PRIMARY]'

    # 2. Partition Schemes (TO ...): Replace TO ([FG1], [FG2], ...) with ALL TO ([PRIMARY])
    $Sql = $Sql -replace '(?<!ALL\s)TO\s*\(\s*(?!\[PRIMARY\]\s*\))\[[^\]]+\](?:\s*,\s*\[[^\]]+\])*\s*\)', 'ALL TO ([PRIMARY])'

    # 3. Partition Schemes (ALL TO ...): Replace ALL TO ([NonPrimary]) with ALL TO ([PRIMARY])
    $Sql = $Sql -replace 'ALL\s+TO\s*\(\s*\[(?!PRIMARY\])[^\]]+\]\s*\)', 'ALL TO ([PRIMARY])'

    return $Sql
}

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "PARTITION SCHEME FILEGROUP TESTS" -ForegroundColor Cyan
Write-Host "Issue #80: removeToPrimary vs partition schemes" -ForegroundColor Cyan
Write-Host "===============================================`n" -ForegroundColor Cyan

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: Regular table ON [FileGroup] is replaced
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "[INFO] Test 1: Regular table ON [FileGroup] replacement" -ForegroundColor Cyan

$sql1 = @"
CREATE TABLE [dbo].[ArchivedOrders] (
    [OrderId] INT PRIMARY KEY,
    [OrderDate] DATETIME2 NOT NULL
) ON [FG_ARCHIVE]
"@

$result1 = Invoke-RemoveToPrimaryTransform -Sql $sql1
$expected1Contains = ') ON [PRIMARY]'
$notExpected1Contains = 'FG_ARCHIVE'

Write-TestResult -TestName "Regular filegroup replaced with PRIMARY" `
    -Passed ($result1 -match [regex]::Escape($expected1Contains)) `
    -Message "Expected '$expected1Contains' in result. Got: $result1"

Write-TestResult -TestName "Original filegroup name removed" `
    -Passed ($result1 -notmatch 'FG_ARCHIVE') `
    -Message "Should not contain FG_ARCHIVE. Got: $result1"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: Table ON [PRIMARY] is left unchanged
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 2: Table ON [PRIMARY] left unchanged" -ForegroundColor Cyan

$sql2 = @"
CREATE TABLE [dbo].[Orders] (
    [OrderId] INT PRIMARY KEY
) ON [PRIMARY]
"@

$result2 = Invoke-RemoveToPrimaryTransform -Sql $sql2
Write-TestResult -TestName "ON [PRIMARY] preserved" `
    -Passed ($result2 -eq $sql2) `
    -Message "SQL should be unchanged. Got: $result2"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3: Partitioned table ON [SchemaName](Column) is preserved (Bug #80)
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 3: Partitioned table ON [SchemeName](Column) preserved (Bug #80)" -ForegroundColor Cyan

$sql3 = @"
CREATE TABLE [Sales].[OrderHistory] (
    [OrderHistoryId] INT IDENTITY(1,1),
    [OrderDate] DATETIME NOT NULL,
    [CustomerId] INT NOT NULL,
    [Amount] DECIMAL(12,2),
    CONSTRAINT [PK_OrderHistory] PRIMARY KEY CLUSTERED ([OrderHistoryId], [OrderDate])
) ON [PS_OrderYear]([OrderDate])
"@

$result3 = Invoke-RemoveToPrimaryTransform -Sql $sql3

Write-TestResult -TestName "Partition scheme reference preserved" `
    -Passed ($result3 -match [regex]::Escape('[PS_OrderYear]([OrderDate])')) `
    -Message "Should keep [PS_OrderYear]([OrderDate]). Got: $result3"

Write-TestResult -TestName "Partition scheme not replaced with PRIMARY" `
    -Passed ($result3 -notmatch 'ON \[PRIMARY\]') `
    -Message "Should NOT have ON [PRIMARY]. Got: $result3"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4: Partitioned table with space before column paren is preserved
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 4: Partitioned table with space before paren preserved" -ForegroundColor Cyan

$sql4 = @"
CREATE TABLE [dbo].[MyTable] (
    [Id] INT NOT NULL,
    [PartCol] INT NOT NULL
) ON [MyPartitionScheme] ([PartCol])
"@

$result4 = Invoke-RemoveToPrimaryTransform -Sql $sql4

Write-TestResult -TestName "Partition scheme with space before paren preserved" `
    -Passed ($result4 -match [regex]::Escape('[MyPartitionScheme]')) `
    -Message "Should keep [MyPartitionScheme]. Got: $result4"

Write-TestResult -TestName "Not replaced with PRIMARY (space variant)" `
    -Passed ($result4 -notmatch 'ON \[PRIMARY\]') `
    -Message "Should NOT have ON [PRIMARY]. Got: $result4"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5: Partition scheme TO clause is collapsed to ALL TO ([PRIMARY])
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 5: Partition scheme TO clause collapsed" -ForegroundColor Cyan

$sql5 = @"
CREATE PARTITION SCHEME [PS_OrderYear]
AS PARTITION [PF_OrderYear]
TO ([FG_ARCHIVE], [FG_CURRENT], [PRIMARY])
"@

$result5 = Invoke-RemoveToPrimaryTransform -Sql $sql5

Write-TestResult -TestName "Partition scheme TO collapsed to ALL TO ([PRIMARY])" `
    -Passed ($result5 -match 'ALL TO \(\[PRIMARY\]\)') `
    -Message "Should have ALL TO ([PRIMARY]). Got: $result5"

Write-TestResult -TestName "Original filegroup list removed" `
    -Passed ($result5 -notmatch 'FG_ARCHIVE' -and $result5 -notmatch 'FG_CURRENT') `
    -Message "Should not contain original filegroups. Got: $result5"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 6: Partition scheme ALL TO ([NonPrimary]) is replaced
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 6: ALL TO ([NonPrimary]) replaced" -ForegroundColor Cyan

$sql6 = @"
CREATE PARTITION SCHEME [PS_Simple]
AS PARTITION [PF_Simple]
ALL TO ([FG_DATA])
"@

$result6 = Invoke-RemoveToPrimaryTransform -Sql $sql6

Write-TestResult -TestName "ALL TO ([FG_DATA]) replaced with ALL TO ([PRIMARY])" `
    -Passed ($result6 -match 'ALL TO \(\[PRIMARY\]\)') `
    -Message "Should have ALL TO ([PRIMARY]). Got: $result6"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 7: ALL TO ([PRIMARY]) already correct is left unchanged
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 7: ALL TO ([PRIMARY]) left unchanged" -ForegroundColor Cyan

$sql7 = @"
CREATE PARTITION SCHEME [PS_Simple]
AS PARTITION [PF_Simple]
ALL TO ([PRIMARY])
"@

$result7 = Invoke-RemoveToPrimaryTransform -Sql $sql7
Write-TestResult -TestName "ALL TO ([PRIMARY]) preserved" `
    -Passed ($result7 -eq $sql7) `
    -Message "SQL should be unchanged. Got: $result7"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 8: TEXTIMAGE_ON [FileGroup] is replaced
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 8: TEXTIMAGE_ON replacement" -ForegroundColor Cyan

$sql8 = @"
CREATE TABLE [dbo].[Documents] (
    [DocumentId] INT IDENTITY(1,1) PRIMARY KEY,
    [Content] NVARCHAR(MAX) NULL
) ON [PRIMARY] TEXTIMAGE_ON [FG_LOB]
"@

$result8 = Invoke-RemoveToPrimaryTransform -Sql $sql8

Write-TestResult -TestName "TEXTIMAGE_ON replaced with PRIMARY" `
    -Passed ($result8 -match 'TEXTIMAGE_ON \[PRIMARY\]') `
    -Message "Should have TEXTIMAGE_ON [PRIMARY]. Got: $result8"

Write-TestResult -TestName "TEXTIMAGE_ON original filegroup removed" `
    -Passed ($result8 -notmatch 'FG_LOB') `
    -Message "Should not contain FG_LOB. Got: $result8"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 9: FILESTREAM_ON [FileGroup] is replaced
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 9: FILESTREAM_ON replacement" -ForegroundColor Cyan

$sql9 = @"
CREATE TABLE [dbo].[FileData] (
    [FileId] INT IDENTITY(1,1) PRIMARY KEY,
    [FileContent] VARBINARY(MAX) FILESTREAM
) ON [PRIMARY] FILESTREAM_ON [FG_STREAM]
"@

$result9 = Invoke-RemoveToPrimaryTransform -Sql $sql9

Write-TestResult -TestName "FILESTREAM_ON replaced with PRIMARY" `
    -Passed ($result9 -match 'FILESTREAM_ON \[PRIMARY\]') `
    -Message "Should have FILESTREAM_ON [PRIMARY]. Got: $result9"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 10: Mixed scenario - table on filegroup + TEXTIMAGE_ON + partition scheme
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 10: Mixed scenario - regular tables + partitioned table" -ForegroundColor Cyan

$sql10_regular = @"
CREATE TABLE [dbo].[RegularTable] (
    [Id] INT PRIMARY KEY,
    [Data] NVARCHAR(MAX)
) ON [FG_DATA] TEXTIMAGE_ON [FG_LOB]
"@

$sql10_partitioned = @"
CREATE TABLE [dbo].[PartitionedTable] (
    [Id] INT NOT NULL,
    [PartDate] DATETIME NOT NULL,
    CONSTRAINT [PK_Partitioned] PRIMARY KEY ([Id], [PartDate])
) ON [PS_DateRange]([PartDate])
"@

$result10_regular = Invoke-RemoveToPrimaryTransform -Sql $sql10_regular
$result10_partitioned = Invoke-RemoveToPrimaryTransform -Sql $sql10_partitioned

Write-TestResult -TestName "Regular table filegroup replaced" `
    -Passed ($result10_regular -match '\) ON \[PRIMARY\]' -and $result10_regular -match 'TEXTIMAGE_ON \[PRIMARY\]') `
    -Message "Regular table should have ON [PRIMARY] and TEXTIMAGE_ON [PRIMARY]. Got: $result10_regular"

Write-TestResult -TestName "Partitioned table scheme preserved" `
    -Passed ($result10_partitioned -match [regex]::Escape('[PS_DateRange]([PartDate])')) `
    -Message "Partitioned table should keep scheme reference. Got: $result10_partitioned"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 11: Index ON [FileGroup] is replaced (indexes use same pattern as tables)
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 11: Index ON [FileGroup] replacement" -ForegroundColor Cyan

$sql11 = @"
CREATE NONCLUSTERED INDEX [IX_Orders_Date]
    ON [dbo].[Orders] ([OrderDate])
) ON [FG_INDEX]
"@

$result11 = Invoke-RemoveToPrimaryTransform -Sql $sql11
Write-TestResult -TestName "Index filegroup replaced with PRIMARY" `
    -Passed ($result11 -match '\) ON \[PRIMARY\]') `
    -Message "Index should have ON [PRIMARY]. Got: $result11"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 12: Partition scheme with single non-PRIMARY filegroup
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 12: Partition scheme with single non-PRIMARY filegroup" -ForegroundColor Cyan

$sql12 = @"
CREATE PARTITION SCHEME [PS_Single]
AS PARTITION [PF_Single]
TO ([FG_DATA])
"@

$result12 = Invoke-RemoveToPrimaryTransform -Sql $sql12

Write-TestResult -TestName "Single filegroup TO collapsed to ALL TO ([PRIMARY])" `
    -Passed ($result12 -match 'ALL TO \(\[PRIMARY\]\)') `
    -Message "Should have ALL TO ([PRIMARY]). Got: $result12"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 13: Partition function is left unchanged (no filegroup references)
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 13: Partition function left unchanged" -ForegroundColor Cyan

$sql13 = @"
CREATE PARTITION FUNCTION [PF_OrderYear](datetime)
AS RANGE RIGHT FOR VALUES ('2025-01-01', '2026-01-01')
"@

$result13 = Invoke-RemoveToPrimaryTransform -Sql $sql13
Write-TestResult -TestName "Partition function unchanged" `
    -Passed ($result13 -eq $sql13) `
    -Message "Partition function should be unchanged. Got: $result13"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 14: Case insensitive PRIMARY detection
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n[INFO] Test 14: Case insensitive PRIMARY detection" -ForegroundColor Cyan

$sql14 = @"
CREATE TABLE [dbo].[Test] (
    [Id] INT PRIMARY KEY
) ON [primary]
"@

$result14 = Invoke-RemoveToPrimaryTransform -Sql $sql14
Write-TestResult -TestName "Lowercase [primary] not double-replaced" `
    -Passed ($result14 -eq $sql14) `
    -Message "ON [primary] should be left as-is. Got: $result14"

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host "`n===============================================" -ForegroundColor Cyan
Write-Host "PARTITION SCHEME FILEGROUP TEST SUMMARY" -ForegroundColor Cyan
Write-Host "===============================================`n" -ForegroundColor Cyan

Write-Host "Tests Passed: $script:testsPassed" -ForegroundColor Green
Write-Host "Tests Failed: $script:testsFailed" -ForegroundColor $(if ($script:testsFailed -gt 0) { 'Red' } else { 'Green' })

if ($script:testsFailed -gt 0) {
    Write-Host "`n[FAILED] Some tests failed!" -ForegroundColor Red
    exit 1
}
else {
    Write-Host "`n[SUCCESS] All tests passed!" -ForegroundColor Green
    exit 0
}
