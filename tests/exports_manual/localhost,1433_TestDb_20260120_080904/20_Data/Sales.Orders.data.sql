SET IDENTITY_INSERT [Sales].[Orders] ON 

INSERT [Sales].[Orders] ([OrderId], [CustomerId], [OrderDate], [TotalAmount], [Status], [OrderXml], [TenantId]) VALUES (1, 1, CAST(N'2026-01-19T04:16:46.667' AS DateTime), CAST(0.00 AS Decimal(12, 2)), N'Pending', NULL, 1)
INSERT [Sales].[Orders] ([OrderId], [CustomerId], [OrderDate], [TotalAmount], [Status], [OrderXml], [TenantId]) VALUES (2, 2, CAST(N'2026-01-19T04:16:46.677' AS DateTime), CAST(0.00 AS Decimal(12, 2)), N'Pending', NULL, 1)
INSERT [Sales].[Orders] ([OrderId], [CustomerId], [OrderDate], [TotalAmount], [Status], [OrderXml], [TenantId]) VALUES (3, 3, CAST(N'2026-01-19T04:16:46.677' AS DateTime), CAST(0.00 AS Decimal(12, 2)), N'Pending', NULL, 1)
SET IDENTITY_INSERT [Sales].[Orders] OFF
GO
