SET IDENTITY_INSERT [Warehouse].[Inventory] ON 

INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (1, 1, N'WH-001', 100, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (2, 2, N'WH-002', 75, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (3, 3, N'WH-003', 50, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (4, 4, N'WH-004', 40, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (5, 5, N'WH-005', 25, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
INSERT [Warehouse].[Inventory] ([InventoryId], [ProductId], [LocationCode], [QuantityOnHand], [LastUpdated]) VALUES (6, 6, N'WH-006', 20, CAST(N'2026-01-19T04:16:46.683' AS DateTime))
SET IDENTITY_INSERT [Warehouse].[Inventory] OFF
GO
