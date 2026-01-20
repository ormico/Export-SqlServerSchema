EXEC sp_create_plan_guide @name = N'[CustomerOrdersPlanGuide]', @stmt = N'SELECT c.CustomerId, c.CustomerName, COUNT(o.OrderId) as OrderCount
FROM dbo.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerId = o.CustomerId
GROUP BY c.CustomerId, c.CustomerName', @type = N'SQL', @module_or_batch = N'SELECT c.CustomerId, c.CustomerName, COUNT(o.OrderId) as OrderCount
FROM dbo.Customers c
LEFT JOIN Sales.Orders o ON c.CustomerId = o.CustomerId
GROUP BY c.CustomerId, c.CustomerName', @hints = N'OPTION (HASH JOIN, MAXDOP 2)'
GO
