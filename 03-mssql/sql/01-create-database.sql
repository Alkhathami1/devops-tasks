/*
 * 01 — Create the database and put it in FULL recovery model.
 *
 * Idempotent: safe to run against an existing instance. Re-running changes
 * nothing, which matters because the drills bring the stack up repeatedly.
 *
 * FULL recovery is not cosmetic here. It is what makes transaction log backups
 * — and therefore point-in-time recovery — possible at all. In SIMPLE recovery
 * the log is truncated at every checkpoint and BACKUP LOG fails outright with
 * Msg 4208. That failure is demonstrated deliberately in the backup drill.
 */

IF DB_ID('AppDb') IS NULL
BEGIN
    PRINT 'Creating database AppDb';
    CREATE DATABASE AppDb;
END
ELSE
    PRINT 'Database AppDb already exists, leaving it alone';
GO

/* FULL recovery model: required for log backups and point-in-time restore. */
IF (SELECT recovery_model_desc FROM sys.databases WHERE name = 'AppDb') <> 'FULL'
BEGIN
    PRINT 'Setting AppDb to FULL recovery model';
    ALTER DATABASE AppDb SET RECOVERY FULL;
END
ELSE
    PRINT 'AppDb already in FULL recovery model';
GO

/*
 * Page verification by checksum. Every page written gets a checksum that is
 * validated on read, so corruption is detected rather than silently served.
 * BACKUP ... WITH CHECKSUM later relies on this to validate pages as they are
 * streamed into the backup file.
 */
IF (SELECT page_verify_option_desc FROM sys.databases WHERE name = 'AppDb') <> 'CHECKSUM'
BEGIN
    PRINT 'Enabling CHECKSUM page verification on AppDb';
    ALTER DATABASE AppDb SET PAGE_VERIFY CHECKSUM;
END
GO

SELECT
    name                    AS [database],
    recovery_model_desc     AS [recovery_model],
    page_verify_option_desc AS [page_verify],
    state_desc              AS [state]
FROM sys.databases
WHERE name = 'AppDb';
GO
