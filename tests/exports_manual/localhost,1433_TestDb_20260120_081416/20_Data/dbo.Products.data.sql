SET IDENTITY_INSERT [dbo].[Products] ON 

INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (1, N'Widget A', N'WDG-001', CAST(19.99 AS Decimal(10, 2)), 100, 1)
INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (2, N'Widget B', N'WDG-002', CAST(29.99 AS Decimal(10, 2)), 75, 1)
INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (3, N'Gadget X', N'GDG-001', CAST(49.99 AS Decimal(10, 2)), 50, 2)
INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (4, N'Gadget Y', N'GDG-002', CAST(59.99 AS Decimal(10, 2)), 40, 2)
INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (5, N'Tool Alpha', N'TL-001', CAST(89.99 AS Decimal(10, 2)), 25, 3)
INSERT [dbo].[Products] ([ProductId], [ProductName], [ProductCode], [Price], [StockQuantity], [CategoryId]) VALUES (6, N'Tool Beta', N'TL-002', CAST(99.99 AS Decimal(10, 2)), 20, 3)
SET IDENTITY_INSERT [dbo].[Products] OFF
GO
