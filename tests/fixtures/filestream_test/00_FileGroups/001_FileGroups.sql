-- FileGroups and Files
-- WARNING: Physical file paths and sizes are environment-specific
-- Review and update via config file before applying to target environment
-- Uses SQLCMD variables: $(FG_NAME_PATH_FILE), $(FG_NAME_SIZE), $(FG_NAME_GROWTH)

-- FileGroup: FG_DATA
-- Type: RowsFileGroup
ALTER DATABASE CURRENT ADD FILEGROUP [FG_DATA];
GO

-- File: TestDb_Data
-- Original Path: E:\SQLData\TestDb_Data.ndf
-- Original Size: 8192KB, Growth: 65536KB, MaxSize: UNLIMITED
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'TestDb_Data',
    FILENAME = N'$(FG_DATA_PATH_FILE)',
    SIZE = $(FG_DATA_SIZE)
    , FILEGROWTH = $(FG_DATA_GROWTH)
    , MAXSIZE = UNLIMITED
) TO FILEGROUP [FG_DATA];
GO

-- FileGroup: FG_FILESTREAM
-- Type: FileStreamDataFileGroup
-- NOTE: FILESTREAM FileGroups are Windows-only (require NTFS)
-- Use stripFilestream option for Linux/container targets
ALTER DATABASE CURRENT ADD FILEGROUP [FG_FILESTREAM] CONTAINS FILESTREAM;
GO

-- Container: TestDb_FileStream (FILESTREAM container - folder, not file)
-- Original Path: F:\FileStreamData\TestDb_FileStream
-- NOTE: FILESTREAM containers are folders, not .ndf files
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'TestDb_FileStream',
    FILENAME = N'$(FG_FILESTREAM_PATH_FILE)'
) TO FILEGROUP [FG_FILESTREAM];
GO
