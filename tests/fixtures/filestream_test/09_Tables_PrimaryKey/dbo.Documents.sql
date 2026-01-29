-- Table: dbo.Documents
-- Contains FILESTREAM column for document storage
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE TABLE [dbo].[Documents](
    [DocumentId] [uniqueidentifier] ROWGUIDCOL NOT NULL,
    [FileName] [nvarchar](255) NOT NULL,
    [Content] [varbinary](max) FILESTREAM NULL,
    [CreatedDate] [datetime2](7) NOT NULL,
    CONSTRAINT [PK_Documents] PRIMARY KEY CLUSTERED ([DocumentId] ASC)
) ON [FG_DATA] FILESTREAM_ON [FG_FILESTREAM];
GO
