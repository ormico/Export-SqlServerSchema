-- Index: IX_Documents_FileName on dbo.Documents
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO
CREATE NONCLUSTERED INDEX [IX_Documents_FileName] ON [dbo].[Documents]
(
    [FileName] ASC
) ON [FG_DATA];
GO
