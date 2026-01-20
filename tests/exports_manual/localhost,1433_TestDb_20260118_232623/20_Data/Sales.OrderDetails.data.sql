SET IDENTITY_INSERT [Sales].[OrderDetails] ON 

INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (1, 1, 1, 2, CAST(19.99 AS Decimal(10, 2)), CAST(0.00 AS Decimal(5, 2)))
INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (2, 1, 3, 1, CAST(49.99 AS Decimal(10, 2)), CAST(5.00 AS Decimal(5, 2)))
INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (3, 2, 2, 3, CAST(29.99 AS Decimal(10, 2)), CAST(10.00 AS Decimal(5, 2)))
INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (4, 2, 4, 1, CAST(59.99 AS Decimal(10, 2)), CAST(0.00 AS Decimal(5, 2)))
INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (5, 3, 5, 1, CAST(89.99 AS Decimal(10, 2)), CAST(15.00 AS Decimal(5, 2)))
INSERT [Sales].[OrderDetails] ([OrderDetailId], [OrderId], [ProductId], [Quantity], [UnitPrice], [Discount]) VALUES (6, 3, 6, 2, CAST(99.99 AS Decimal(10, 2)), CAST(10.00 AS Decimal(5, 2)))
SET IDENTITY_INSERT [Sales].[OrderDetails] OFF
GO
