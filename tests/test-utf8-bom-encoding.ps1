#Requires -Version 7.0

<#
.SYNOPSIS
    Unit tests for UTF-8 BOM encoding in exported SQL files.

.DESCRIPTION
    Validates that all file-writing code paths in Export-SqlServerSchema.ps1
    produce UTF-8 with BOM (byte order mark). Tests cover:
    1. Static source code analysis - verifying encoding parameters are correct
    2. Out-File / Set-Content encoding behavior with utf8BOM
    3. [System.IO.File]::WriteAllText with UTF8Encoding($true) for BOM
    4. SMO ScriptingOptions configuration for UTF-8 BOM
    5. Unicode content preservation through write/read round-trip

.NOTES
    Does NOT require a SQL Server connection. All tests run locally.
#>

$ErrorActionPreference = 'Stop'
$scriptDir = $PSScriptRoot
$projectRoot = Split-Path $scriptDir -Parent

$exportScript = Join-Path $projectRoot 'Export-SqlServerSchema.ps1'

$testsPassed = 0
$testsFailed = 0

function Write-TestResult {
    param([string]$TestName, [bool]$Passed, [string]$Message = '')
    if ($Passed) {
        Write-Host "[PASS] $TestName" -ForegroundColor Green
        $script:testsPassed++
    }
    else {
        Write-Host "[FAIL] $TestName" -ForegroundColor Red
        if ($Message) { Write-Host "       $Message" -ForegroundColor Yellow }
        $script:testsFailed++
    }
}

function Test-Utf8Bom {
    <#
    .SYNOPSIS
        Checks whether a file starts with the UTF-8 BOM (EF BB BF).
    #>
    param([string]$FilePath)
    $bytes = [System.IO.File]::ReadAllBytes($FilePath)
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

# ─────────────────────────────────────────────────────────────────────────────
# Setup: Create temporary directory for test files
# ─────────────────────────────────────────────────────────────────────────────

$tempDir = Join-Path $env:TEMP "utf8bom-tests-$(New-Guid)"
$null = New-Item -ItemType Directory -Path $tempDir -Force

Write-Host ''
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host 'UTF-8 BOM ENCODING TESTS' -ForegroundColor Cyan
Write-Host 'Validating that exported SQL files use UTF-8 with BOM.' -ForegroundColor Cyan
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 1: Static Source Code Analysis
# Verify the export script contains correct encoding settings
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 1: Static Source Code Analysis ──' -ForegroundColor Cyan
Write-Host ''

$scriptContent = Get-Content -Path $exportScript -Raw

# Test 1: New-ScriptingOptions uses AnsiFile = $false
$ansiFileFalseInDefaults = $scriptContent -match 'AnsiFile\s*=\s*\$false'
Write-TestResult 'New-ScriptingOptions sets AnsiFile = $false' $ansiFileFalseInDefaults

# Test 2: No remaining AnsiFile = $true in production code
# Count occurrences of AnsiFile = $true vs AnsiFile = $false
$ansiTrueMatches = [regex]::Matches($scriptContent, '\$(?:scripter\.Options|Scripter\.Options|options)\.AnsiFile\s*=\s*\$true')
$ansiTrueInDefaults = [regex]::Matches($scriptContent, 'AnsiFile\s*=\s*\$true')
$totalAnsiTrue = $ansiTrueMatches.Count + $ansiTrueInDefaults.Count
Write-TestResult 'No remaining AnsiFile = $true in source' ($totalAnsiTrue -eq 0) `
    "Found $totalAnsiTrue occurrence(s) of AnsiFile = `$true"

# Test 3: UTF8Encoding with BOM ($true) is used in New-ScriptingOptions defaults
$utf8BomInDefaults = $scriptContent -match 'Encoding\s*=\s*\[System\.Text\.UTF8Encoding\]::new\(\$true\)'
Write-TestResult 'New-ScriptingOptions defaults include UTF8Encoding BOM' $utf8BomInDefaults

# Test 4: Parallel worker sets UTF8 BOM encoding on scripter options
$parallelEncodingMatches = [regex]::Matches($scriptContent, '\$scripter\.Options\.Encoding\s*=\s*\[System\.Text\.UTF8Encoding\]::new\(\$true\)')
Write-TestResult 'Parallel worker sets UTF8 BOM on scripter.Options.Encoding' ($parallelEncodingMatches.Count -ge 1) `
    "Found $($parallelEncodingMatches.Count) match(es), expected >= 1"

# Test 5: Process-ExportWorkItem sets UTF8 BOM encoding
$processExportEncoding = [regex]::Matches($scriptContent, '\$Scripter\.Options\.Encoding\s*=\s*\[System\.Text\.UTF8Encoding\]::new\(\$true\)')
Write-TestResult 'Process-ExportWorkItem sets UTF8 BOM on Scripter.Options.Encoding' ($processExportEncoding.Count -ge 1) `
    "Found $($processExportEncoding.Count) match(es), expected >= 1"

# Test 6: No UTF8Encoding($false) remains for SQL file writes
$utf8NoBomMatches = [regex]::Matches($scriptContent, 'UTF8Encoding[^)]*\$false')
Write-TestResult 'No UTF8Encoding($false) in source (no-BOM removed)' ($utf8NoBomMatches.Count -eq 0) `
    "Found $($utf8NoBomMatches.Count) occurrence(s) of UTF8Encoding `$false"

# Test 7: Out-File for .sql/.md files uses utf8BOM encoding
# Filter to only .sql/.md related writes (exclude JSON metadata/metrics files)
$allOutFileUtf8 = [regex]::Matches($scriptContent, 'Out-File\s+-FilePath\s+\$\w+\s+-Encoding\s+UTF8\b(?!BOM)')
$sqlOutFileUtf8Count = 0
foreach ($m in $allOutFileUtf8) {
    $lineStart = $scriptContent.LastIndexOf("`n", $m.Index) + 1
    $lineEnd = $scriptContent.IndexOf("`n", $m.Index)
    if ($lineEnd -lt 0) { $lineEnd = $scriptContent.Length }
    $line = $scriptContent.Substring($lineStart, $lineEnd - $lineStart)
    # Skip JSON file writes (metadata, metrics) - they are not .sql files
    if ($line -notmatch 'metadataPath|metricsFile') {
        $sqlOutFileUtf8Count++
    }
}
Write-TestResult 'No Out-File -Encoding UTF8 (without BOM) for SQL/MD export files' ($sqlOutFileUtf8Count -eq 0) `
    "Found $sqlOutFileUtf8Count Out-File call(s) for SQL/MD files still using plain UTF8"

# Test 8: Out-File uses utf8BOM (positive check)
$outFileBomMatches = [regex]::Matches($scriptContent, 'Out-File\s+.*-Encoding\s+utf8BOM')
Write-TestResult 'Out-File calls use -Encoding utf8BOM' ($outFileBomMatches.Count -ge 3) `
    "Found $($outFileBomMatches.Count) match(es), expected >= 3 (FileGroups, DbConfig, DbCreds)"

# Test 9: Set-Content for strip FILESTREAM uses utf8BOM
$setContentBomMatches = [regex]::Matches($scriptContent, 'Set-Content\s+.*-Encoding\s+utf8BOM')
Write-TestResult 'Set-Content uses -Encoding utf8BOM for strip FILESTREAM' ($setContentBomMatches.Count -ge 1) `
    "Found $($setContentBomMatches.Count) match(es), expected >= 1"

# Test 10: SecurityPolicy WriteAllText uses UTF8Encoding($true)
$writeAllTextBomMatches = [regex]::Matches($scriptContent, 'WriteAllText\([^,]+,\s*[^,]+,\s*\[System\.Text\.UTF8Encoding\]::new\(\$true\)\)')
Write-TestResult 'SecurityPolicy WriteAllText uses UTF8Encoding BOM' ($writeAllTextBomMatches.Count -ge 2) `
    "Found $($writeAllTextBomMatches.Count) match(es), expected >= 2 (parallel + sequential)"

# Test 11: SecurityPolicy AppendAllText uses UTF8Encoding($true)
$appendAllTextBomMatches = [regex]::Matches($scriptContent, 'AppendAllText\([^,]+,\s*[^,]+,\s*\[System\.Text\.UTF8Encoding\]::new\(\$true\)\)')
Write-TestResult 'SecurityPolicy AppendAllText uses UTF8Encoding BOM' ($appendAllTextBomMatches.Count -ge 2) `
    "Found $($appendAllTextBomMatches.Count) match(es), expected >= 2 (parallel + sequential)"

# Test 12: Deployment manifest uses utf8BOM
$manifestBomMatch = $scriptContent -match 'manifestContent\s*\|\s*Out-File\s+.*-Encoding\s+utf8BOM'
Write-TestResult 'Deployment manifest uses -Encoding utf8BOM' $manifestBomMatch

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 2: Out-File -Encoding utf8BOM Behavioral Tests
# Verify that Out-File with utf8BOM actually writes BOM bytes
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 2: Out-File utf8BOM Behavioral Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 13: Out-File with utf8BOM writes BOM bytes
$outFileBomPath = Join-Path $tempDir 'outfile-bom.sql'
"SELECT 1;" | Out-File -FilePath $outFileBomPath -Encoding utf8BOM
Write-TestResult 'Out-File -Encoding utf8BOM writes BOM bytes' (Test-Utf8Bom -FilePath $outFileBomPath)

# Test 14: Out-File with plain UTF8 does NOT write BOM (control test)
$outFileNoBomPath = Join-Path $tempDir 'outfile-no-bom.sql'
"SELECT 1;" | Out-File -FilePath $outFileNoBomPath -Encoding UTF8
$hasNoBom = -not (Test-Utf8Bom -FilePath $outFileNoBomPath)
Write-TestResult 'Out-File -Encoding UTF8 does NOT write BOM (control)' $hasNoBom

# Test 15: Out-File utf8BOM preserves unicode content
$unicodeContent = "-- Comment with unicode: cafe`u{0301} na`u{00EF}ve r`u{00E9}sum`u{00E9} `u{2603} `u{2764}"
$outFileUnicodePath = Join-Path $tempDir 'outfile-unicode.sql'
$unicodeContent | Out-File -FilePath $outFileUnicodePath -Encoding utf8BOM
$readBack = Get-Content -Path $outFileUnicodePath -Raw -Encoding utf8
$contentMatch = $readBack.TrimEnd() -eq $unicodeContent
Write-TestResult 'Out-File utf8BOM preserves unicode content' $contentMatch `
    "Written: $unicodeContent | Read: $($readBack.TrimEnd())"

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 3: Set-Content -Encoding utf8BOM Behavioral Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 3: Set-Content utf8BOM Behavioral Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 16: Set-Content with utf8BOM writes BOM bytes
$setContentBomPath = Join-Path $tempDir 'setcontent-bom.sql'
Set-Content -Path $setContentBomPath -Value "CREATE TABLE [dbo].[Test] ([Id] INT);" -Encoding utf8BOM
Write-TestResult 'Set-Content -Encoding utf8BOM writes BOM bytes' (Test-Utf8Bom -FilePath $setContentBomPath)

# Test 17: Set-Content utf8BOM with -NoNewline writes BOM bytes
$setContentNoNewlinePath = Join-Path $tempDir 'setcontent-nonewline-bom.sql'
"ALTER TABLE [dbo].[Test] ADD [Col] NVARCHAR(50);" | Set-Content -Path $setContentNoNewlinePath -Encoding utf8BOM -NoNewline
Write-TestResult 'Set-Content -Encoding utf8BOM -NoNewline writes BOM' (Test-Utf8Bom -FilePath $setContentNoNewlinePath)

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 4: [System.IO.File]::WriteAllText UTF8 BOM Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 4: WriteAllText UTF8 BOM Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 18: WriteAllText with UTF8Encoding($true) writes BOM
$writeAllTextBomPath = Join-Path $tempDir 'writealltext-bom.sql'
$utf8Bom = [System.Text.UTF8Encoding]::new($true)
[System.IO.File]::WriteAllText($writeAllTextBomPath, "-- Security Policy header`r`n", $utf8Bom)
Write-TestResult 'WriteAllText with UTF8Encoding($true) writes BOM' (Test-Utf8Bom -FilePath $writeAllTextBomPath)

# Test 19: AppendAllText with UTF8Encoding($true) preserves BOM
$appendBomPath = Join-Path $tempDir 'append-bom.sql'
[System.IO.File]::WriteAllText($appendBomPath, "-- Header`r`n", $utf8Bom)
[System.IO.File]::AppendAllText($appendBomPath, "-- Appended line`r`n", $utf8Bom)
Write-TestResult 'AppendAllText preserves BOM from initial write' (Test-Utf8Bom -FilePath $appendBomPath)
$appendContent = [System.IO.File]::ReadAllText($appendBomPath, $utf8Bom)
$hasAppendedContent = $appendContent -match 'Appended line'
Write-TestResult 'AppendAllText content is correct' $hasAppendedContent

# Test 20: WriteAllText with UTF8Encoding($false) does NOT write BOM (control test)
$writeAllTextNoBomPath = Join-Path $tempDir 'writealltext-no-bom.sql'
$utf8NoBom = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText($writeAllTextNoBomPath, "-- No BOM`r`n", $utf8NoBom)
$hasNoBom = -not (Test-Utf8Bom -FilePath $writeAllTextNoBomPath)
Write-TestResult 'WriteAllText with UTF8Encoding($false) has no BOM (control)' $hasNoBom

# Test 21: WriteAllText UTF8 BOM preserves unicode characters
$unicodeSql = "-- Row-Level Security Policy: dbo.caf`u{00E9}Policy`r`n-- Unicode: `u{00E9}`u{00E8}`u{00EA} `u{00FC}`u{00F6}`u{00E4} `u{2603}`r`n"
$unicodeWritePath = Join-Path $tempDir 'writealltext-unicode-bom.sql'
[System.IO.File]::WriteAllText($unicodeWritePath, $unicodeSql, $utf8Bom)
Write-TestResult 'WriteAllText BOM with unicode has BOM' (Test-Utf8Bom -FilePath $unicodeWritePath)
$unicodeReadBack = [System.IO.File]::ReadAllText($unicodeWritePath, $utf8Bom)
Write-TestResult 'WriteAllText BOM unicode round-trip preserves content' ($unicodeReadBack -eq $unicodeSql) `
    "Content mismatch on round-trip"

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 5: StringBuilder + Out-File Pattern Tests (FileGroups, DbConfig, DbCreds)
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 5: StringBuilder + Out-File Pattern Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 22: StringBuilder content piped to Out-File utf8BOM writes BOM
$sbBomPath = Join-Path $tempDir 'stringbuilder-bom.sql'
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("-- Database Scoped Configurations")
[void]$sb.AppendLine("ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = 4;")
[void]$sb.AppendLine("GO")
$sb.ToString() | Out-File -FilePath $sbBomPath -Encoding utf8BOM
Write-TestResult 'StringBuilder | Out-File utf8BOM writes BOM' (Test-Utf8Bom -FilePath $sbBomPath)

# Test 23: StringBuilder content is intact after Out-File utf8BOM
$sbReadBack = Get-Content -Path $sbBomPath -Raw -Encoding utf8
$hasDbConfig = $sbReadBack -match 'ALTER DATABASE SCOPED CONFIGURATION'
Write-TestResult 'StringBuilder content intact after Out-File utf8BOM' $hasDbConfig

# Test 24: StringBuilder with unicode content preserves characters
$sbUnicodePath = Join-Path $tempDir 'stringbuilder-unicode-bom.sql'
$sbUni = New-Object System.Text.StringBuilder
[void]$sbUni.AppendLine("-- Credential: caf`u{00E9}_credential")
[void]$sbUni.AppendLine("-- Identity: user@`u{00E9}xample.com")
[void]$sbUni.AppendLine("CREATE DATABASE SCOPED CREDENTIAL [`u{00E9}test]")
$sbUni.ToString() | Out-File -FilePath $sbUnicodePath -Encoding utf8BOM
Write-TestResult 'StringBuilder unicode | Out-File utf8BOM writes BOM' (Test-Utf8Bom -FilePath $sbUnicodePath)
$sbUniReadBack = Get-Content -Path $sbUnicodePath -Raw -Encoding utf8
$hasUnicodeContent = $sbUniReadBack -match "`u{00E9}test"
Write-TestResult 'StringBuilder unicode content preserved' $hasUnicodeContent

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 6: Strip FILESTREAM Pattern (Set-Content -Encoding utf8BOM -NoNewline)
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 6: Strip FILESTREAM Re-write Pattern Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 25: Set-Content -NoNewline preserves exact content with BOM
$stripPath = Join-Path $tempDir 'strip-filestream-bom.sql'
$originalContent = "CREATE TABLE [dbo].[Documents](`r`n    [Id] INT PRIMARY KEY,`r`n    [Data] VARBINARY(MAX)`r`n);"
$originalContent | Set-Content -Path $stripPath -Encoding utf8BOM -NoNewline
Write-TestResult 'Strip pattern: Set-Content -NoNewline writes BOM' (Test-Utf8Bom -FilePath $stripPath)
$stripReadBack = Get-Content -Path $stripPath -Raw -Encoding utf8
Write-TestResult 'Strip pattern: content preserved exactly' ($stripReadBack -eq $originalContent) `
    "Content mismatch"

# Test 26: Re-writing a file that originally had BOM still has BOM
$rewritePath = Join-Path $tempDir 'rewrite-bom.sql'
"ORIGINAL CONTENT" | Out-File -FilePath $rewritePath -Encoding utf8BOM
$content = Get-Content -Path $rewritePath -Raw
$content = $content -replace 'ORIGINAL', 'MODIFIED'
$content | Set-Content -Path $rewritePath -Encoding utf8BOM -NoNewline
Write-TestResult 'Re-written file retains BOM' (Test-Utf8Bom -FilePath $rewritePath)
$rewriteReadBack = Get-Content -Path $rewritePath -Raw -Encoding utf8
$hasModified = $rewriteReadBack -match 'MODIFIED CONTENT'
Write-TestResult 'Re-written file has modified content' $hasModified

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 7: UTF8Encoding Object Consistency Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 7: UTF8Encoding Object Consistency ──' -ForegroundColor Cyan
Write-Host ''

# Test 27: UTF8Encoding($true) preamble contains BOM bytes
$enc = [System.Text.UTF8Encoding]::new($true)
$preamble = $enc.GetPreamble()
$hasBomPreamble = ($preamble.Length -eq 3 -and $preamble[0] -eq 0xEF -and $preamble[1] -eq 0xBB -and $preamble[2] -eq 0xBF)
Write-TestResult 'UTF8Encoding($true) preamble is EF BB BF' $hasBomPreamble

# Test 28: UTF8Encoding($false) preamble is empty
$encNoBom = [System.Text.UTF8Encoding]::new($false)
$preambleNoBom = $encNoBom.GetPreamble()
Write-TestResult 'UTF8Encoding($false) preamble is empty' ($preambleNoBom.Length -eq 0)

# Test 29: Multiple instantiations produce consistent results
$enc1 = [System.Text.UTF8Encoding]::new($true)
$enc2 = [System.Text.UTF8Encoding]::new($true)
$path1 = Join-Path $tempDir 'consistency1.sql'
$path2 = Join-Path $tempDir 'consistency2.sql'
[System.IO.File]::WriteAllText($path1, "SELECT 1;`r`n", $enc1)
[System.IO.File]::WriteAllText($path2, "SELECT 1;`r`n", $enc2)
$bytes1 = [System.IO.File]::ReadAllBytes($path1)
$bytes2 = [System.IO.File]::ReadAllBytes($path2)
$bytesEqual = ($bytes1.Length -eq $bytes2.Length)
if ($bytesEqual) {
    for ($i = 0; $i -lt $bytes1.Length; $i++) {
        if ($bytes1[$i] -ne $bytes2[$i]) { $bytesEqual = $false; break }
    }
}
Write-TestResult 'Multiple UTF8Encoding($true) instances produce identical output' $bytesEqual

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 8: Extended Unicode Character Tests
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 8: Extended Unicode Character Tests ──' -ForegroundColor Cyan
Write-Host ''

# Test 30: CJK characters survive round-trip with BOM
$cjkPath = Join-Path $tempDir 'cjk-bom.sql'
$cjkContent = "-- CJK: `u{4E2D}`u{6587}`u{6D4B}`u{8BD5} `u{65E5}`u{672C}`u{8A9E} `u{D55C}`u{AD6D}`u{C5B4}`r`nSELECT N'`u{4E2D}`u{6587}';`r`nGO`r`n"
[System.IO.File]::WriteAllText($cjkPath, $cjkContent, [System.Text.UTF8Encoding]::new($true))
Write-TestResult 'CJK content file has BOM' (Test-Utf8Bom -FilePath $cjkPath)
$cjkReadBack = [System.IO.File]::ReadAllText($cjkPath, [System.Text.UTF8Encoding]::new($true))
Write-TestResult 'CJK characters survive round-trip' ($cjkReadBack -eq $cjkContent)

# Test 31: Emoji and supplementary plane characters survive round-trip with BOM
$emojiPath = Join-Path $tempDir 'emoji-bom.sql'
$emojiContent = "-- Emoji: `u{1F600}`u{1F4BB}`u{1F680}`r`nSELECT N'`u{1F600}';`r`nGO`r`n"
[System.IO.File]::WriteAllText($emojiPath, $emojiContent, [System.Text.UTF8Encoding]::new($true))
Write-TestResult 'Emoji content file has BOM' (Test-Utf8Bom -FilePath $emojiPath)
$emojiReadBack = [System.IO.File]::ReadAllText($emojiPath, [System.Text.UTF8Encoding]::new($true))
Write-TestResult 'Emoji characters survive round-trip' ($emojiReadBack -eq $emojiContent)

# Test 32: Mixed ASCII and unicode in typical SQL pattern
$mixedPath = Join-Path $tempDir 'mixed-bom.sql'
$mixedContent = @"
-- Stored Procedure: dbo.Get`u{00C9}mployee
-- Contains accented characters in comments and string literals
CREATE PROCEDURE [dbo].[Get`u{00C9}mployee]
    @Name NVARCHAR(100)
AS
BEGIN
    SELECT * FROM [dbo].[`u{00C9}mployees]
    WHERE [Name] = @Name
    -- R`u{00E9}sum`u{00E9} search with na`u{00EF}ve matching
END
GO
"@
$mixedContent | Out-File -FilePath $mixedPath -Encoding utf8BOM
Write-TestResult 'Mixed ASCII/unicode SQL has BOM' (Test-Utf8Bom -FilePath $mixedPath)
$mixedReadBack = Get-Content -Path $mixedPath -Raw -Encoding utf8
$hasAccented = $mixedReadBack -match "`u{00C9}mployee" -and $mixedReadBack -match "R`u{00E9}sum`u{00E9}"
Write-TestResult 'Mixed ASCII/unicode SQL content preserved' $hasAccented

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Section 9: Edge Cases
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '── Section 9: Edge Cases ──' -ForegroundColor Cyan
Write-Host ''

# Test 33: Empty string written with BOM still has BOM bytes
$emptyBomPath = Join-Path $tempDir 'empty-bom.sql'
[System.IO.File]::WriteAllText($emptyBomPath, "", [System.Text.UTF8Encoding]::new($true))
$emptyBytes = [System.IO.File]::ReadAllBytes($emptyBomPath)
$emptyHasBom = ($emptyBytes.Length -ge 3 -and $emptyBytes[0] -eq 0xEF -and $emptyBytes[1] -eq 0xBB -and $emptyBytes[2] -eq 0xBF)
Write-TestResult 'Empty string WriteAllText still writes BOM' $emptyHasBom

# Test 34: Very long SQL content preserves BOM
$longPath = Join-Path $tempDir 'long-bom.sql'
$longSb = New-Object System.Text.StringBuilder
[void]$longSb.AppendLine("-- Long SQL file test")
for ($i = 0; $i -lt 1000; $i++) {
    [void]$longSb.AppendLine("INSERT INTO [dbo].[TestTable] ([Id], [Value]) VALUES ($i, N'`u{00E9}ntry_$i');")
}
[void]$longSb.AppendLine("GO")
$longSb.ToString() | Out-File -FilePath $longPath -Encoding utf8BOM
Write-TestResult 'Long SQL file (1000+ lines) has BOM' (Test-Utf8Bom -FilePath $longPath)
$longReadBack = Get-Content -Path $longPath -Raw -Encoding utf8
$hasLastEntry = $longReadBack -match "`u{00E9}ntry_999"
Write-TestResult 'Long SQL file preserves unicode in last entry' $hasLastEntry

# Test 35: BOM is exactly 3 bytes at start of file
$exactBomPath = Join-Path $tempDir 'exact-bom.sql'
"SELECT 1;" | Out-File -FilePath $exactBomPath -Encoding utf8BOM
$exactBytes = [System.IO.File]::ReadAllBytes($exactBomPath)
$bomCorrect = ($exactBytes[0] -eq 0xEF -and $exactBytes[1] -eq 0xBB -and $exactBytes[2] -eq 0xBF)
# Byte at index 3 should be the start of actual content (not another BOM)
$noDuplicateBom = ($exactBytes.Length -lt 6 -or -not ($exactBytes[3] -eq 0xEF -and $exactBytes[4] -eq 0xBB -and $exactBytes[5] -eq 0xBF))
Write-TestResult 'BOM is exactly 3 bytes EF BB BF at file start' $bomCorrect
Write-TestResult 'No duplicate BOM bytes' $noDuplicateBom

Write-Host ''

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup
# ─────────────────────────────────────────────────────────────────────────────

try {
    Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
}
catch {
    Write-Host "[WARNING] Could not clean up temp directory: $tempDir" -ForegroundColor Yellow
}

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────

Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan
Write-Host "RESULTS: $testsPassed passed, $testsFailed failed" -ForegroundColor $(if ($testsFailed -gt 0) { 'Red' } else { 'Green' })
Write-Host '═══════════════════════════════════════════════════════════════' -ForegroundColor Cyan

if ($testsFailed -gt 0) {
    exit 1
}
else {
    exit 0
}
