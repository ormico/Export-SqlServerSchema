SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER OFF
GO

-- Create a view
CREATE VIEW Sales.vw_CustomerOrders
AS
SELECT 
    c.CustomerId,
    c.CustomerName,
    c.Email,
    o.OrderId,
    o.OrderDate,
    o.TotalAmount,
    o.Status
FROM dbo.Customers c
INNER JOIN Sales.Orders o ON c.CustomerId = o.CustomerId;
GO
