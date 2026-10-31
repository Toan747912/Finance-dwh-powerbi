/* =====================================================================
   01_restore.sql  -  Restore AdventureWorks2022 (OLTP) vao SQL Server
   Chay tren: master (SSMS, Windows). Chay lai nhieu lan an toan.
   Phong thu (TC-ENV-01, TC-ENV-02):
     - Kiem tra phien ban SQL Server truoc khi restore
     - Kiem tra file .bak ton tai va dung luong trong cua o dia
     - DB da ton tai -> bo qua (tru khi @force_restore = 1)
     - Loi giua chung -> tra DB ve MULTI_USER, bao loi ro rang
   ===================================================================== */
SET NOCOUNT ON;

-- ------------------------- THAM SO: SUA O DAY -------------------------
DECLARE @bak_path      NVARCHAR(500) = N'C:\Backup\AdventureWorks2022.bak'; -- SQL Server (service) phai doc duoc duong dan nay
DECLARE @src_db        SYSNAME       = N'AdventureWorks2022';
DECLARE @logical_data  SYSNAME       = N'AdventureWorks2022';      -- ten logical file du lieu trong .bak
DECLARE @logical_log   SYSNAME       = N'AdventureWorks2022_log';  -- ten logical file log trong .bak
DECLARE @min_major_ver INT           = 16;    -- file AdventureWorks2022.bak can SQL Server 2022 (16.x) tro len
DECLARE @min_free_mb   INT           = 1024;  -- dung luong trong toi thieu moi o dia (MB)
DECLARE @force_restore BIT           = 0;     -- 1 = ghi de DB da ton tai
-- -----------------------------------------------------------------------

DECLARE @data_dir NVARCHAR(500) = CONVERT(NVARCHAR(500), SERVERPROPERTY('InstanceDefaultDataPath'));
DECLARE @log_dir  NVARCHAR(500) = CONVERT(NVARCHAR(500), SERVERPROPERTY('InstanceDefaultLogPath'));
DECLARE @sql              NVARCHAR(MAX);
DECLARE @msg              NVARCHAR(2000);
DECLARE @file_exists      INT = NULL;
DECLARE @free_data        INT = NULL;
DECLARE @free_log         INT = NULL;
DECLARE @single_user_set  BIT = 0;
DECLARE @row_count        BIGINT;

BEGIN TRY
    -- 1. Phien ban SQL Server
    IF CAST(SERVERPROPERTY('ProductMajorVersion') AS INT) < @min_major_ver
    BEGIN
        SET @msg = N'SQL Server hien tai la v' + CONVERT(NVARCHAR(50), SERVERPROPERTY('ProductVersion'))
                 + N'. File AdventureWorks2022.bak yeu cau SQL Server 2022 (' + CAST(@min_major_ver AS NVARCHAR(10))
                 + N'.x) tro len. Nang cap SQL Server hoac bao lai de doi sang ban AdventureWorks tuong thich.';
        THROW 50001, @msg, 1;
    END;

    -- 2. Da ton tai?
    IF DB_ID(@src_db) IS NOT NULL AND @force_restore = 0
    BEGIN
        PRINT N'[01_restore] Database ' + @src_db + N' da ton tai. Bo qua restore (dat @force_restore = 1 de ghi de).';
    END
    ELSE
    BEGIN
        -- 3. Thu muc dich
        IF @data_dir IS NULL OR @log_dir IS NULL
        BEGIN
            SET @msg = N'Khong xac dinh duoc thu muc data/log mac dinh cua instance (SERVERPROPERTY tra ve NULL).';
            THROW 50002, @msg, 1;
        END;
        IF RIGHT(@data_dir, 1) <> N'\' SET @data_dir = @data_dir + N'\';
        IF RIGHT(@log_dir,  1) <> N'\' SET @log_dir  = @log_dir  + N'\';

        -- 4. File .bak ton tai? (best-effort; neu khong kiem tra duoc thi de RESTORE bao loi)
        BEGIN TRY
            DECLARE @f TABLE (file_exists INT, is_directory INT, parent_exists INT);
            INSERT INTO @f EXEC master.dbo.xp_fileexist @bak_path;
            SELECT @file_exists = file_exists FROM @f;
        END TRY
        BEGIN CATCH
            PRINT N'CANH BAO: khong kiem tra truoc duoc file .bak (' + ERROR_MESSAGE() + N'). RESTORE se bao loi neu co.';
        END CATCH;
        IF @file_exists = 0
        BEGIN
            SET @msg = N'Khong thay file .bak tai: ' + @bak_path + N'. Kiem tra duong dan va quyen doc cua tai khoan dich vu SQL Server.';
            THROW 50003, @msg, 1;
        END;

        -- 5. Dung luong trong (best-effort)
        BEGIN TRY
            DECLARE @d TABLE (drive CHAR(1), mb_free INT);
            INSERT INTO @d EXEC master.dbo.xp_fixeddrives;
            SELECT @free_data = mb_free FROM @d WHERE drive = LEFT(@data_dir, 1);
            SELECT @free_log  = mb_free FROM @d WHERE drive = LEFT(@log_dir, 1);
        END TRY
        BEGIN CATCH
            PRINT N'CANH BAO: khong kiem tra duoc dung luong o dia (' + ERROR_MESSAGE() + N').';
        END CATCH;
        IF (@free_data IS NOT NULL AND @free_data < @min_free_mb)
           OR (@free_log IS NOT NULL AND @free_log < @min_free_mb)
        BEGIN
            SET @msg = N'Khong du dung luong trong. Data: ' + COALESCE(CAST(@free_data AS NVARCHAR(20)), N'?')
                     + N' MB, Log: ' + COALESCE(CAST(@free_log AS NVARCHAR(20)), N'?')
                     + N' MB, can toi thieu ' + CAST(@min_free_mb AS NVARCHAR(20)) + N' MB moi o dia.';
            THROW 50004, @msg, 1;
        END;
        IF @free_data IS NULL OR @free_log IS NULL
            PRINT N'CANH BAO: khong xac dinh duoc dung luong trong cua o dia dich (o mount/UNC?). Tu kiem tra thu cong.';

        -- 6. Dong ket noi cu neu ghi de
        IF DB_ID(@src_db) IS NOT NULL
        BEGIN
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@src_db) + N' SET SINGLE_USER WITH ROLLBACK IMMEDIATE;';
            EXEC sys.sp_executesql @sql;
            SET @single_user_set = 1;
        END;

        -- 7. Restore
        SET @sql = N'RESTORE DATABASE ' + QUOTENAME(@src_db)
                 + N' FROM DISK = N''' + REPLACE(@bak_path, N'''', N'''''') + N''''
                 + N' WITH ' + CASE WHEN @force_restore = 1 THEN N'REPLACE, ' ELSE N'' END
                 + N'MOVE N''' + REPLACE(@logical_data, N'''', N'''''') + N''' TO N'''
                 + REPLACE(@data_dir, N'''', N'''''') + REPLACE(@src_db, N'''', N'''''') + N'.mdf'', '
                 + N'MOVE N''' + REPLACE(@logical_log, N'''', N'''''') + N''' TO N'''
                 + REPLACE(@log_dir, N'''', N'''''') + REPLACE(@src_db, N'''', N'''''') + N'_log.ldf'', '
                 + N'STATS = 10;';
        EXEC sys.sp_executesql @sql;
        SET @single_user_set = 0;
    END;

    -- 8. Kiem tra sau restore
    SET @sql = N'SELECT @n = COUNT_BIG(*) FROM ' + QUOTENAME(@src_db) + N'.Sales.SalesOrderDetail;';
    EXEC sys.sp_executesql @sql, N'@n BIGINT OUTPUT', @n = @row_count OUTPUT;
    IF @row_count = 0
    BEGIN
        SET @msg = N'Restore xong nhung Sales.SalesOrderDetail rong. Kiem tra lai file .bak.';
        THROW 50005, @msg, 1;
    END;
    PRINT N'[01_restore] OK. ' + @src_db + N': Sales.SalesOrderDetail co ' + CAST(@row_count AS NVARCHAR(30)) + N' dong.';
END TRY
BEGIN CATCH
    DECLARE @err NVARCHAR(2000) =
        N'[01_restore] Loi ' + CAST(ERROR_NUMBER() AS NVARCHAR(20))
        + N' (dong ' + CAST(ERROR_LINE() AS NVARCHAR(20)) + N'): ' + ERROR_MESSAGE();

    IF ERROR_NUMBER() = 3234
        SET @err = @err + N' Goi y: chay RESTORE FILELISTONLY FROM DISK = N''<duong dan .bak>'' de lay ten logical file dung, roi sua @logical_data/@logical_log.';
    IF ERROR_NUMBER() IN (3169, 3241)
        SET @err = @err + N' Goi y: file .bak co the sai dinh dang hoac duoc tao tu phien ban SQL Server moi hon instance nay.';
    IF ERROR_NUMBER() = 3013
        SET @err = @err + N' Goi y: loi goc (khong mo duoc file, sai phien ban, file hong...) bi TRY/CATCH che mat. Mo cua so query MOI va chay: RESTORE FILELISTONLY FROM DISK = N'''
                        + REPLACE(@bak_path, N'''', N'''''') + N'''; de thay loi that.';

    -- Tra DB ve MULTI_USER neu da lo chuyen SINGLE_USER ma restore that bai
    IF @single_user_set = 1 AND DB_ID(@src_db) IS NOT NULL
    BEGIN
        BEGIN TRY
            SET @sql = N'ALTER DATABASE ' + QUOTENAME(@src_db) + N' SET MULTI_USER;';
            EXEC sys.sp_executesql @sql;
        END TRY
        BEGIN CATCH
            SET @err = @err + N' CANH BAO: khong tra duoc DB ve MULTI_USER: ' + ERROR_MESSAGE();
        END CATCH;
    END;

    SET @err = LEFT(@err, 2000);
    THROW 50009, @err, 1;
END CATCH;
