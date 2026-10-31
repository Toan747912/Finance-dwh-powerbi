/* =====================================================================
   06_etl_procs.sql  -  Chay ETL toan bo bang 1 lenh + doi chieu du lieu
   Chay tren: FinanceDW (sau 01..05). Chay lai nhieu lan an toan.
   Dung:
     EXEC ops.usp_run_etl;          -- stg -> dims -> facts -> doi chieu
     EXEC ops.usp_reconcile;        -- chi doi chieu (khong nap)
   Phong thu:
     - Dung ngay khi 1 giai doan loi (khong chay tiep giai doan sau)
     - Moi lan chay ghi 1 dong tong hop step = 'pipeline' vao ops.etl_log
     - Doi chieu that bai => pipeline FAILED (loi 50071)
   Ma loi: 50070 giai doan loi | 50071 doi chieu that bai | 50072 tham so sai
   ===================================================================== */
USE FinanceDW;
GO
SET NOCOUNT ON;
GO

-- ------------------------- Doi chieu src/stg/dwh -------------------------
-- Tra ve 1 result set (check_name, expected, actual, status) va @failed_count.
CREATE OR ALTER PROCEDURE ops.usp_reconcile
    @failed_count INT = NULL OUTPUT,
    @quiet        BIT = 0              -- 1 = khong tra result set (dung khi goi tu proc khac)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @chk TABLE (
        seq        INT IDENTITY(1,1) PRIMARY KEY,
        check_name NVARCHAR(200) NOT NULL,
        expected   DECIMAL(38,6) NULL,
        actual     DECIMAL(38,6) NULL,
        status     VARCHAR(8)    NOT NULL
    );

    BEGIN TRY
        -- 1. stg = src (so dong) cho moi bang trong metadata
        DECLARE @objs TABLE (n INT IDENTITY(1,1) PRIMARY KEY, synonym_name SYSNAME, stg_table SYSNAME);
        INSERT INTO @objs (synonym_name, stg_table)
        SELECT synonym_name, stg_table FROM ops.source_object ORDER BY load_order;

        DECLARE @i INT = 1, @n INT = (SELECT COUNT(*) FROM @objs);
        DECLARE @syn SYSNAME, @stg SYSNAME, @sql NVARCHAR(MAX), @a BIGINT, @b BIGINT;
        WHILE @i <= @n
        BEGIN
            SELECT @syn = synonym_name, @stg = stg_table FROM @objs WHERE n = @i;
            SET @sql = N'SELECT @s = COUNT_BIG(*) FROM src.' + QUOTENAME(@syn)
                     + N'; SELECT @t = COUNT_BIG(*) FROM stg.' + QUOTENAME(@stg) + N';';
            EXEC sys.sp_executesql @sql, N'@s BIGINT OUTPUT, @t BIGINT OUTPUT', @s = @a OUTPUT, @t = @b OUTPUT;
            INSERT INTO @chk (check_name, expected, actual, status)
            VALUES (N'stg.' + @stg + N' = src', @a, @b, CASE WHEN @a = @b THEN 'PASS' ELSE 'FAIL' END);
            SET @i += 1;
        END;

        -- 2. Dimension (khong tinh dong Unknown key = -1) = stg
        INSERT INTO @chk (check_name, expected, actual, status)
        SELECT v.check_name, v.expected, v.actual, CASE WHEN v.expected = v.actual THEN 'PASS' ELSE 'FAIL' END
          FROM (VALUES
            (N'dwh.dim_product = stg.Product',        (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.Product),      (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_product     WHERE product_key     > 0)),
            (N'dwh.dim_customer = stg.Customer',      (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.Customer),     (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_customer    WHERE customer_key    > 0)),
            (N'dwh.dim_territory = stg.SalesTerritory',(SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.SalesTerritory),(SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_territory   WHERE territory_key   > 0)),
            (N'dwh.dim_salesperson = stg.SalesPerson',(SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.SalesPerson),   (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_salesperson WHERE salesperson_key > 0)),
            (N'dwh.dim_vendor = stg.Vendor',          (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.Vendor),       (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_vendor      WHERE vendor_key      > 0))
          ) AS v (check_name, expected, actual);

        -- 3. Dong Unknown (-1) ton tai dung 1 lan trong moi dimension
        INSERT INTO @chk (check_name, expected, actual, status)
        SELECT v.check_name, 1, v.actual, CASE WHEN v.actual = 1 THEN 'PASS' ELSE 'FAIL' END
          FROM (VALUES
            (N'dwh.dim_product co dong Unknown',     (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_product     WHERE product_key     = -1)),
            (N'dwh.dim_customer co dong Unknown',    (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_customer    WHERE customer_key    = -1)),
            (N'dwh.dim_territory co dong Unknown',   (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_territory   WHERE territory_key   = -1)),
            (N'dwh.dim_salesperson co dong Unknown', (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_salesperson WHERE salesperson_key = -1)),
            (N'dwh.dim_vendor co dong Unknown',      (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.dim_vendor      WHERE vendor_key      = -1))
          ) AS v (check_name, actual);

        -- 4. Fact: so dong nap + so dong bi tu choi (lan chay gan nhat thanh cong) = so dong stg
        DECLARE @rej_s INT, @rej_p INT, @rej_q INT;
        SELECT TOP (1) @rej_s = rows_rejected FROM ops.etl_log WHERE step = N'dwh.fact_sales'      AND status = 'SUCCESS' ORDER BY log_id DESC;
        SELECT TOP (1) @rej_p = rows_rejected FROM ops.etl_log WHERE step = N'dwh.fact_purchasing' AND status = 'SUCCESS' ORDER BY log_id DESC;
        SELECT TOP (1) @rej_q = rows_rejected FROM ops.etl_log WHERE step = N'dwh.fact_quota'      AND status = 'SUCCESS' ORDER BY log_id DESC;

        INSERT INTO @chk (check_name, expected, actual, status)
        SELECT v.check_name, v.expected, v.actual,
               CASE WHEN v.rej IS NULL THEN 'FAIL' WHEN v.expected = v.actual THEN 'PASS' ELSE 'FAIL' END
          FROM (VALUES
            (N'fact_sales + reject = stg.SalesOrderDetail',
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.SalesOrderDetail),
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.fact_sales) + COALESCE(@rej_s, 0), @rej_s),
            (N'fact_purchasing + reject = stg.PurchaseOrderDetail',
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.PurchaseOrderDetail),
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.fact_purchasing) + COALESCE(@rej_p, 0), @rej_p),
            (N'fact_quota + reject = stg.SalesPersonQuotaHistory',
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM stg.SalesPersonQuotaHistory),
                (SELECT CAST(COUNT(*) AS DECIMAL(38,6)) FROM dwh.fact_quota) + COALESCE(@rej_q, 0), @rej_q)
          ) AS v (check_name, expected, actual, rej);

        -- 5. Doanh thu fact_sales = tong LineTotal cua cac dong da nap
        DECLARE @rev_exp DECIMAL(38,6), @rev_act DECIMAL(38,6);
        SELECT @rev_exp = SUM(CAST(d.LineTotal AS DECIMAL(38,6)))
          FROM stg.SalesOrderDetail AS d
          JOIN dwh.fact_sales AS f ON f.sales_order_id = d.SalesOrderID AND f.sales_order_detail_id = d.SalesOrderDetailID;
        SELECT @rev_act = SUM(CAST(revenue AS DECIMAL(38,6))) FROM dwh.fact_sales;
        INSERT INTO @chk (check_name, expected, actual, status)
        VALUES (N'SUM(fact_sales.revenue) = SUM(stg LineTotal)', @rev_exp, @rev_act,
                CASE WHEN @rev_exp = @rev_act THEN 'PASS' ELSE 'FAIL' END);

        -- 6. gross_profit = revenue - cogs tren toan bang
        DECLARE @gp_bad INT;
        SELECT @gp_bad = COUNT(*) FROM dwh.fact_sales WHERE gross_profit <> revenue - cogs;
        INSERT INTO @chk (check_name, expected, actual, status)
        VALUES (N'fact_sales: dong sai gross_profit = revenue - cogs', 0, @gp_bad, CASE WHEN @gp_bad = 0 THEN 'PASS' ELSE 'FAIL' END);
    END TRY
    BEGIN CATCH
        INSERT INTO @chk (check_name, expected, actual, status)
        VALUES (LEFT(N'Loi khi doi chieu ' + CAST(ERROR_NUMBER() AS NVARCHAR(20)) + N': ' + ERROR_MESSAGE(), 200), NULL, NULL, 'FAIL');
    END CATCH;

    SELECT @failed_count = COUNT(*) FROM @chk WHERE status <> 'PASS';

    IF @quiet = 0
        SELECT check_name, expected, actual, status FROM @chk ORDER BY seq;
END;
GO

-- ------------------------- Chay ETL toan bo -------------------------
CREATE OR ALTER PROCEDURE ops.usp_run_etl
    @simulate_fail_stage VARCHAR(10) = NULL   -- CHI DUNG CHO TEST: 'stg' | 'dims' | 'facts'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT OFF;   -- loi o giai doan con duoc bat bang TRY/CATCH, khong huy ca batch

    DECLARE @run_id     UNIQUEIDENTIFIER = NEWID();
    DECLARE @t0         DATETIME2(3) = SYSUTCDATETIME();
    DECLARE @stage      NVARCHAR(30) = N'init';
    DECLARE @failed     BIT = 0;
    DECLARE @err_no     INT = NULL;
    DECLARE @err_msg    NVARCHAR(4000) = NULL;
    DECLARE @final_msg  NVARCHAR(2000);
    DECLARE @rec_failed INT = 0;
    DECLARE @read       INT = 0, @loaded INT = 0, @rejected INT = 0;
    DECLARE @sim        SYSNAME = NULL;

    BEGIN TRY
        IF @simulate_fail_stage IS NOT NULL AND @simulate_fail_stage NOT IN ('stg', 'dims', 'facts')
        BEGIN
            SET @err_msg = N'Tham so @simulate_fail_stage chi nhan NULL | stg | dims | facts.';
            THROW 50072, @err_msg, 1;
        END;

        SET @stage = N'stg';
        SET @sim = CASE WHEN @simulate_fail_stage = 'stg' THEN N'Product' END;
        EXEC stg.usp_load_all @simulate_fail_after = @sim;

        SET @stage = N'dims';
        SET @sim = CASE WHEN @simulate_fail_stage = 'dims' THEN N'dim_date' END;
        EXEC dwh.usp_load_dims @simulate_fail_after = @sim;

        SET @stage = N'facts';
        SET @sim = CASE WHEN @simulate_fail_stage = 'facts' THEN N'fact_sales' END;
        EXEC dwh.usp_load_facts @simulate_fail_after = @sim;

        SET @stage = N'reconcile';
        EXEC ops.usp_reconcile @failed_count = @rec_failed OUTPUT, @quiet = 1;
        IF @rec_failed > 0
        BEGIN
            SET @err_msg = CAST(@rec_failed AS NVARCHAR(20)) + N' kiem tra doi chieu that bai. Chay EXEC ops.usp_reconcile; de xem chi tiet.';
            THROW 50071, @err_msg, 1;
        END;
    END TRY
    BEGIN CATCH
        SET @failed  = 1;
        SET @err_no  = ERROR_NUMBER();
        SET @err_msg = LEFT(ERROR_MESSAGE(), 4000);
        IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;   -- khong de transaction mo sot lai
    END CATCH;

    -- So lieu tong hop (best-effort: loi o day khong duoc che mat ket qua pipeline)
    BEGIN TRY
        SELECT @read     = COUNT(*) FROM stg.SalesOrderDetail;
        SELECT @loaded   = COUNT(*) FROM dwh.fact_sales;
        SELECT @rejected = @read - @loaded;
        IF @rejected < 0 SET @rejected = 0;
    END TRY
    BEGIN CATCH
        SELECT @read = 0, @loaded = 0, @rejected = 0;
    END CATCH;

    DECLARE @final_err NVARCHAR(4000) =
        CASE WHEN @failed = 1 THEN LEFT(N'Giai doan ' + @stage + N': ' + COALESCE(@err_msg, N'(khong ro)'), 4000) END;

    INSERT INTO ops.etl_log (run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
    VALUES (@run_id, N'pipeline', @t0, SYSUTCDATETIME(), @read, @loaded, @rejected,
            CASE WHEN @failed = 1 THEN 'FAILED' ELSE 'SUCCESS' END, @err_no, @final_err);

    IF @failed = 1
    BEGIN
        SET @final_msg = LEFT(N'ops.usp_run_etl that bai. ' + @final_err, 2000);
        THROW 50070, @final_msg, 1;
    END;

    PRINT N'[usp_run_etl] OK trong ' + CAST(DATEDIFF(MILLISECOND, @t0, SYSUTCDATETIME()) / 1000.0 AS NVARCHAR(30)) + N' giay.';
END;
GO
