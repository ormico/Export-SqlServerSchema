-- CLR Assembly script for testing
-- This uses a minimal .NET assembly binary (will fail without CLR enabled)
CREATE ASSEMBLY [TestClrAssembly]
    AUTHORIZATION [dbo]
    FROM 0x4D5A90000300000004000000FFFF0000
    WITH PERMISSION_SET = SAFE
GO
