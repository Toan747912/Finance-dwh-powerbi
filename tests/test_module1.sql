/* =====================================================================
   tests/test_module1.sql
   Bao phu: TC-ENV-03, TC-ETL-01, TC-ETL-02, TC-ETL-07, TC-DQ-01, TC-DQ-02
   Chay SAU 01, 02, 03. Ket qua: bang PASS/FAIL o cuoi script.
   Script nay chay proc nap stg nhieu lan (mat vai chuc giay).

   KHONG tu dong hoa duoc (kiem tra thu cong, ghi ket qua vao README sau):
     TC-ENV-01: dat @min_free_mb trong 01_restore.sql lon hon dung luong trong thuc te,
                dat @force_restore = 1 -> script phai dung SOM, bao loi 50004, khong restore do.
     TC-ENV-02: tro @bak_path toi file khong phai .bak -> phai bao loi ro (50009 kem goi y),
                DB nguon (neu co) van o MULTI_USER.
   TC-ENV-04 : chay `pytest tests/test_config.py` (Python).
   ===================================================================== */
USE FinanceDW;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF OBJECT_ID(N'tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (test_id VARCHAR(20) NOT NULL, result VARCHAR(4) NOT NULL, detail NVARCHAR(1000) NULL);

DECLARE @res  VARCHAR(4);
DECLARE @det  NVARCHAR(1000);
DECLARE @res7 VARCHAR(4);
DECLARE @det7 NVARCHAR(1000);

-- ------------------------------------------------------------------
-- TC-ENV-03a: nguon day du -> validate khong loi
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC ops.usp_validate_source;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ENV-03a', @res, @det);

-- ------------------------------------------------------------------
-- TC-ENV-03b: cot khong ton tai -> loi 50011 neu dung ten cot
-- (chen metadata gia trong transaction, ROLLBACK sau do)
-- ------------------------------------------------------------------
SET @res = 'FAIL'; SET @det = N'validate khong bao loi du thieu cot';
BEGIN TRANSACTION;
BEGIN TRY
    INSERT INTO ops.source_column (schema_name, table_name, column_name, stg_column_name, ordinal)
    VALUES (N'Sales', N'SalesOrderHeader', N'NoSuchColumn', N'NoSuchColumn', 99);
    EXEC ops.usp_validate_source;
END TRY
BEGIN CATCH
    IF ERROR_NUMBER() = 50011 AND ERROR_MESSAGE() LIKE N'%NoSuchColumn%'
    BEGIN SET @res = 'PASS'; SET @det = NULL; END
    ELSE
    BEGIN SET @res = 'FAIL'; SET @det = LEFT(CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': ' + ERROR_MESSAGE(), 1000); END
END CATCH;
IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
INSERT INTO #r VALUES ('TC-ENV-03b', @res, @det);

-- ------------------------------------------------------------------
-- TC-ETL-01: chay 2 lan lien tiep -> so dong va tong tien khong doi
-- ------------------------------------------------------------------
DECLARE @rows1 BIGINT, @rows2 BIGINT, @sum1 DECIMAL(38,6), @sum2 DECIMAL(38,6);
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC stg.usp_load_all;
    EXEC ops.usp_stg_snapshot @rows = @rows1 OUTPUT, @amount_sum = @sum1 OUTPUT;
    EXEC stg.usp_load_all;
    EXEC ops.usp_stg_snapshot @rows = @rows2 OUTPUT, @amount_sum = @sum2 OUTPUT;
    IF NOT (@rows1 > 0 AND @rows1 = @rows2 AND @sum1 = @sum2)
    BEGIN
        SET @res = 'FAIL';
        SET @det = N'lan1: ' + CAST(@rows1 AS NVARCHAR(30)) + N' dong / ' + CAST(@sum1 AS NVARCHAR(50))
                 + N'; lan2: ' + CAST(@rows2 AS NVARCHAR(30)) + N' dong / ' + CAST(@sum2 AS NVARCHAR(50));
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ETL-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-ETL-02 + TC-ETL-07: loi gia lap giua chung -> ROLLBACK + log dung
-- Cach kiem chung ROLLBACK: xoa 1 dong stg.Product (bang nap TRUOC diem loi).
-- Neu transaction da commit, lan nap lai se tra dong do ve. Con thieu 1 dong = da rollback.
-- ------------------------------------------------------------------
DECLARE @prod_before INT, @prod_after INT, @caught BIT, @err_no INT, @err_msg NVARCHAR(4000);
DECLARE @run UNIQUEIDENTIFIER, @n_failed INT, @n_success INT, @n_rolled INT;
DECLARE @f_step NVARCHAR(128), @f_msg NVARCHAR(4000), @f_start DATETIME2(3), @f_end DATETIME2(3);

SET @res  = 'FAIL'; SET @det  = N'khong chay duoc';
SET @res7 = 'FAIL'; SET @det7 = N'khong chay duoc';
SET @caught = 0;
BEGIN TRY
    EXEC stg.usp_load_all;                       -- dua stg ve trang thai sach
    DELETE TOP (1) FROM stg.Product;             -- dau vet de kiem chung rollback
    SELECT @prod_before = COUNT(*) FROM stg.Product;

    BEGIN TRY
        EXEC stg.usp_load_all @simulate_fail_after = N'SalesOrderDetail';
    END TRY
    BEGIN CATCH
        SET @caught = 1; SET @err_no = ERROR_NUMBER(); SET @err_msg = ERROR_MESSAGE();
    END CATCH;

    SELECT @prod_after = COUNT(*) FROM stg.Product;
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;

    SELECT @n_failed  = SUM(CASE WHEN status = 'FAILED'      THEN 1 ELSE 0 END),
           @n_success = SUM(CASE WHEN status = 'SUCCESS'     THEN 1 ELSE 0 END),
           @n_rolled  = SUM(CASE WHEN status = 'ROLLED_BACK' THEN 1 ELSE 0 END)
      FROM ops.etl_log WHERE run_id = @run;

    IF @caught = 1 AND @err_no = 50020 AND @prod_after = @prod_before
       AND @n_failed = 1 AND @n_success = 0 AND @n_rolled >= 1
    BEGIN
        SET @res = 'PASS'; SET @det = NULL;
    END
    ELSE
    BEGIN
        SET @res = 'FAIL';
        SET @det = N'caught=' + CAST(@caught AS NVARCHAR(5)) + N', err=' + COALESCE(CAST(@err_no AS NVARCHAR(20)), N'NULL')
                 + N', Product truoc/sau=' + CAST(@prod_before AS NVARCHAR(20)) + N'/' + CAST(@prod_after AS NVARCHAR(20))
                 + N', FAILED/SUCCESS/ROLLED_BACK=' + CAST(@n_failed AS NVARCHAR(20)) + N'/' + CAST(@n_success AS NVARCHAR(20)) + N'/' + CAST(@n_rolled AS NVARCHAR(20));
    END;

    -- TC-ETL-07: dung 1 dong FAILED, co thoi diem, ten buoc, thong bao
    SELECT @f_step = step, @f_msg = error_message, @f_start = start_time, @f_end = end_time
      FROM ops.etl_log WHERE run_id = @run AND status = 'FAILED';
    IF @n_failed = 1 AND @f_step IS NOT NULL AND NULLIF(LTRIM(RTRIM(@f_msg)), N'') IS NOT NULL
       AND @f_start IS NOT NULL AND @f_end IS NOT NULL
    BEGIN
        SET @res7 = 'PASS'; SET @det7 = NULL;
    END
    ELSE
    BEGIN
        SET @res7 = 'FAIL'; SET @det7 = N'so dong FAILED = ' + COALESCE(CAST(@n_failed AS NVARCHAR(20)), N'NULL') + N'; thieu step/message/thoi gian';
    END;

    EXEC stg.usp_load_all;                       -- don dep: tra stg ve trang thai day du
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ETL-02', @res,  @det);
INSERT INTO #r VALUES ('TC-ETL-07', @res7, @det7);

-- ------------------------------------------------------------------
-- TC-DQ-01: doi chieu tong tien nguon vs stg (chenh lech = 0)
-- ------------------------------------------------------------------
DECLARE @cmp TABLE (metric VARCHAR(40), src_val DECIMAL(38,6), stg_val DECIMAL(38,6));
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    INSERT INTO @cmp VALUES
      ('SOD.LineTotal',
        (SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM src.Sales_SalesOrderDetail),
        (SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM stg.SalesOrderDetail));
    INSERT INTO @cmp VALUES
      ('SOH.SubTotal',
        (SELECT CAST(SUM(SubTotal) AS DECIMAL(38,6)) FROM src.Sales_SalesOrderHeader),
        (SELECT CAST(SUM(SubTotal) AS DECIMAL(38,6)) FROM stg.SalesOrderHeader));
    INSERT INTO @cmp VALUES
      ('SOH.TotalDue',
        (SELECT CAST(SUM(TotalDue) AS DECIMAL(38,6)) FROM src.Sales_SalesOrderHeader),
        (SELECT CAST(SUM(TotalDue) AS DECIMAL(38,6)) FROM stg.SalesOrderHeader));
    INSERT INTO @cmp VALUES
      ('POD.LineTotal',
        (SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM src.Purchasing_PurchaseOrderDetail),
        (SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM stg.PurchaseOrderDetail));
    INSERT INTO @cmp VALUES
      ('Quota.SalesQuota',
        (SELECT CAST(SUM(SalesQuota) AS DECIMAL(38,6)) FROM src.Sales_SalesPersonQuotaHistory),
        (SELECT CAST(SUM(SalesQuota) AS DECIMAL(38,6)) FROM stg.SalesPersonQuotaHistory));

    IF EXISTS (SELECT 1 FROM @cmp WHERE src_val IS NULL OR stg_val IS NULL OR src_val <> stg_val)
    BEGIN
        SET @res = 'FAIL';
        SET @det = LEFT((SELECT STRING_AGG(metric + N': nguon=' + COALESCE(CAST(src_val AS NVARCHAR(50)), N'NULL')
                                         + N' stg=' + COALESCE(CAST(stg_val AS NVARCHAR(50)), N'NULL'), N'; ')
                           FROM @cmp WHERE src_val IS NULL OR stg_val IS NULL OR src_val <> stg_val), 1000);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-02: so dong nguon = so dong stg, cho TAT CA bang trong ops.source_object
-- ------------------------------------------------------------------
IF OBJECT_ID(N'tempdb..#cnt') IS NOT NULL DROP TABLE #cnt;
CREATE TABLE #cnt (tbl SYSNAME, src_cnt BIGINT, stg_cnt BIGINT);
DECLARE @sql NVARCHAR(MAX), @tables INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @tables = COUNT(*) FROM ops.source_object;
    SET @sql = (
        SELECT STRING_AGG(CAST(
            N'SELECT N''' + o.stg_table + N''', (SELECT COUNT_BIG(*) FROM src.' + QUOTENAME(o.synonym_name)
          + N'), (SELECT COUNT_BIG(*) FROM stg.' + QUOTENAME(o.stg_table) + N')' AS NVARCHAR(MAX)), N' UNION ALL ')
        FROM ops.source_object AS o);
    INSERT INTO #cnt EXEC sys.sp_executesql @sql;

    IF (SELECT COUNT(*) FROM #cnt) <> @tables OR EXISTS (SELECT 1 FROM #cnt WHERE src_cnt <> stg_cnt OR src_cnt = 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = LEFT(COALESCE((SELECT STRING_AGG(tbl + N': nguon=' + CAST(src_cnt AS NVARCHAR(20)) + N' stg=' + CAST(stg_cnt AS NVARCHAR(20)), N'; ')
                                    FROM #cnt WHERE src_cnt <> stg_cnt OR src_cnt = 0), N'so bang doi chieu khong khop'), 1000);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-02', @res, @det);

-- ------------------------------------------------------------------
-- Ket qua
-- ------------------------------------------------------------------
SELECT test_id, result, detail FROM #r ORDER BY test_id;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed,
       SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END) AS failed
  FROM #r;
