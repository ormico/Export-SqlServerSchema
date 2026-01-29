-- Table: dbo.RegularTable
-- Non-FILESTREAM table for comparison
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[RegularTable](
    [Id] [int] IDENTITY(1,1) NOT NULL,
    [Name] [nvarchar](100) NOT NULL,
    [Description] [nvarchar](max) NULL,
    [CreatedDate] [datetime2](7) NOT NULL DEFAULT (GETUTCDATE()),
    CONSTRAINT [PK_RegularTable] PRIMARY KEY CLUSTERED ([Id] ASC)
) ON [FG_DATA];
GO
