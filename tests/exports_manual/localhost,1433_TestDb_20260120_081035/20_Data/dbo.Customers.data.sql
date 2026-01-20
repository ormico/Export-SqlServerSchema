SET IDENTITY_INSERT [dbo].[Customers] ON 

INSERT [dbo].[Customers] ([CustomerId], [CustomerName], [Email], [PhoneNumber], [CreatedDate], [ModifiedDate], [ProfileXml], [AltPhone], [IsActive]) VALUES (1, N'John Doe', N'john.doe@example.com', N'555-0100', CAST(N'2026-01-19T04:16:46.643' AS DateTime), NULL, NULL, NULL, NULL)
INSERT [dbo].[Customers] ([CustomerId], [CustomerName], [Email], [PhoneNumber], [CreatedDate], [ModifiedDate], [ProfileXml], [AltPhone], [IsActive]) VALUES (2, N'Jane Smith', N'jane.smith@example.com', N'555-0101', CAST(N'2026-01-19T04:16:46.643' AS DateTime), NULL, NULL, NULL, NULL)
INSERT [dbo].[Customers] ([CustomerId], [CustomerName], [Email], [PhoneNumber], [CreatedDate], [ModifiedDate], [ProfileXml], [AltPhone], [IsActive]) VALUES (3, N'Bob Johnson', N'bob.johnson@example.com', N'555-0102', CAST(N'2026-01-19T04:16:46.643' AS DateTime), NULL, NULL, NULL, NULL)
INSERT [dbo].[Customers] ([CustomerId], [CustomerName], [Email], [PhoneNumber], [CreatedDate], [ModifiedDate], [ProfileXml], [AltPhone], [IsActive]) VALUES (4, N'Alice Williams', N'alice.williams@example.com', N'555-0103', CAST(N'2026-01-19T04:16:46.643' AS DateTime), NULL, NULL, NULL, NULL)
INSERT [dbo].[Customers] ([CustomerId], [CustomerName], [Email], [PhoneNumber], [CreatedDate], [ModifiedDate], [ProfileXml], [AltPhone], [IsActive]) VALUES (5, N'Charlie Brown', N'charlie.brown@example.com', N'555-0104', CAST(N'2026-01-19T04:16:46.643' AS DateTime), NULL, NULL, NULL, NULL)
SET IDENTITY_INSERT [dbo].[Customers] OFF
GO
