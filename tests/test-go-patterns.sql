-- Test file for GO delimiter variations
-- This file tests various GO patterns that should be handled correctly

-- Pre-cleanup to avoid conflicts from previous runs
DROP TABLE IF EXISTS ##Test1, ##Test2, ##Test3, ##Test4, ##Test5;
GO

-- Test 1: Standard GO
CREATE TABLE ##Test1 (ID INT);
GO

-- Test 2: GO with trailing spaces
CREATE TABLE ##Test2 (ID INT);
GO  

-- Test 3: GO with inline comment
CREATE TABLE ##Test3 (ID INT);
GO -- This creates the table

-- Test 4: GO with leading spaces
CREATE TABLE ##Test4 (ID INT);
  GO

-- Test 5: GO with repeat count (inserts 3 rows)
CREATE TABLE ##Test5 (ID INT IDENTITY(1,1));
GO
INSERT INTO ##Test5 DEFAULT VALUES
GO 3

-- Validation: Check all tables were created
IF OBJECT_ID('tempdb..##Test1') IS NOT NULL PRINT 'Test1: PASS' ELSE PRINT 'Test1: FAIL';
IF OBJECT_ID('tempdb..##Test2') IS NOT NULL PRINT 'Test2: PASS' ELSE PRINT 'Test2: FAIL';
IF OBJECT_ID('tempdb..##Test3') IS NOT NULL PRINT 'Test3: PASS' ELSE PRINT 'Test3: FAIL';
IF OBJECT_ID('tempdb..##Test4') IS NOT NULL PRINT 'Test4: PASS' ELSE PRINT 'Test4: FAIL';
IF OBJECT_ID('tempdb..##Test5') IS NOT NULL 
    AND (SELECT COUNT(*) FROM ##Test5) = 3 
    PRINT 'Test5: PASS' 
ELSE 
    PRINT 'Test5: FAIL';
GO

-- Cleanup
DROP TABLE IF EXISTS ##Test1, ##Test2, ##Test3, ##Test4, ##Test5;
GO
