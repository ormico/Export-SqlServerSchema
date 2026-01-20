SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

-- Create security predicate function
CREATE FUNCTION dbo.fn_TenantAccessPredicate(@TenantId INT)
RETURNS TABLE
WITH SCHEMABINDING
AS
RETURN 
    SELECT 1 AS fn_TenantAccessPredicate_result
    WHERE 
        @TenantId = CAST(SESSION_CONTEXT(N'TenantId') AS INT)
        OR IS_MEMBER('db_owner') = 1  -- Admins bypass RLS
        OR ORIGINAL_LOGIN() = 'sa';   -- SA bypasses RLS
GO
