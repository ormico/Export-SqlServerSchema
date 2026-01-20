-- FileGroups and Files
-- WARNING: Physical file paths are environment-specific
-- Review and update file paths before applying to target environment

-- FileGroup: FG_ARCHIVE
-- Type: RowsFileGroup
ALTER DATABASE CURRENT ADD FILEGROUP [FG_ARCHIVE];
GO

-- File: TestDb_Archive
-- Original Path: /var/opt/mssql/data/TestDb_Archive.ndf
-- Size: 8192KB, Growth: 65536KB, MaxSize: UNLIMITED
-- NOTE: Uses SQLCMD variable $(FG_ARCHIVE_PATH) for base directory path
-- Target server will append appropriate path separator and filename
-- Configure via fileGroupPathMapping in config file or pass as SQLCMD variable
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'TestDb_Archive',
    FILENAME = N'$(FG_ARCHIVE_PATH_FILE)',
    SIZE = 8192KB
    , FILEGROWTH = 65536KB
    , MAXSIZE = UNLIMITED
) TO FILEGROUP [FG_ARCHIVE];
GO

-- FileGroup: FG_CURRENT
-- Type: RowsFileGroup
ALTER DATABASE CURRENT ADD FILEGROUP [FG_CURRENT];
GO

-- File: TestDb_Current
-- Original Path: /var/opt/mssql/data/TestDb_Current.ndf
-- Size: 8192KB, Growth: 65536KB, MaxSize: UNLIMITED
-- NOTE: Uses SQLCMD variable $(FG_CURRENT_PATH) for base directory path
-- Target server will append appropriate path separator and filename
-- Configure via fileGroupPathMapping in config file or pass as SQLCMD variable
ALTER DATABASE CURRENT ADD FILE (
    NAME = N'TestDb_Current',
    FILENAME = N'$(FG_CURRENT_PATH_FILE)',
    SIZE = 8192KB
    , FILEGROWTH = 65536KB
    , MAXSIZE = UNLIMITED
) TO FILEGROUP [FG_CURRENT];
GO


