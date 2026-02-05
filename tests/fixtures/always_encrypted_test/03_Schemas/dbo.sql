-- Schema: dbo
-- This schema already exists by default, but included for completeness
IF NOT EXISTS (SELECT 1 FROM sys.schemas WHERE name = N'dbo')
BEGIN
    EXEC('CREATE SCHEMA [dbo]');
END
GO
