-- Row-Level Security Policy: Sales.TenantSecurityPolicy
-- NOTE: Ensure predicate functions are created before applying this policy

CREATE SECURITY POLICY [Sales].[TenantSecurityPolicy] 
ADD FILTER PREDICATE [dbo].[fn_TenantAccessPredicate]([TenantId]) ON [Sales].[Orders],
ADD BLOCK PREDICATE [dbo].[fn_TenantAccessPredicate]([TenantId]) ON [Sales].[Orders] AFTER INSERT
WITH (STATE = OFF, SCHEMABINDING = ON)
GO

