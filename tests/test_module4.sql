/* =====================================================================
   tests/test_module4.sql
   Bao phu: TC-PIPE-01 (1 lenh + DoD #4 <= 60s), TC-PIPE-02 (chay lai idempotent),
            TC-PIPE-03 (doi chieu 100% PASS), TC-PIPE-04 (loi stg -> dung, khong chay tiep),
            TC-PIPE-05 (loi facts -> fact rollback, stg/dims giu nguyen), TC-PIPE-06 (tham so sai),
            TC-PIPE-07 (doi chieu bat duoc du lieu bi sua), TC-ETL-06 (log pipeline day du)
   Chay SAU 01..06. Ket qua: bang PASS/FAIL o cuoi script.
   Script chay ETL day du nhieu lan (moi lan vai chuc giay) va cuoi cung nap lai sach.
   ===================================================================== */
USE FinanceDW;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF OBJECT_ID(N'tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (test_id VARCHAR(20) NOT NULL, result VARCHAR(4) NOT NULL, detail NVARCHAR(1000) NULL);

DECLARE @res VARCHAR(4);
DECLARE @det NVARCHAR(1000);
DECLARE @maxlog BIGINT;
DECLARE @p_status VARCHAR(12), @p_start DATETIME2(3), @p_end DATETIME2(3), @p_errno INT, @p_msg NVARCHAR(4000);
DECLARE @p_read INT, @p_loaded INT, @p_rej INT, @secs DECIMAL(10,3);

-- ------------------------------------------------------------------
-- TC-PIPE-01 + TC-ETL-06: 1 lenh chay het; log 'pipeline' SUCCESS; thoi gian <= 60s (DoD #4)
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @maxlog = COALESCE(MAX(log_id), 0) FROM ops.etl_log;
    EXEC ops.usp_run_etl;

    SELECT TOP (1) @p_status = status, @p_start = start_time, @p_end = end_time,
                   @p_read = rows_read, @p_loaded = rows_loaded, @p_rej = rows_rejected, @p_msg = error_message
      FROM ops.etl_log WHERE step = N'pipeline' AND log_id > @maxlog ORDER BY log_id DESC;
    SET @secs = DATEDIFF(MILLISECOND, @p_start, @p_end) / 1000.0;

    DECLARE @n_stg INT, @n_dim INT, @n_fact INT;
    SELECT @n_stg  = COUNT(*) FROM ops.etl_log WHERE log_id > @maxlog AND step LIKE N'stg.%';
    SELECT @n_dim  = COUNT(*) FROM ops.etl_log WHERE log_id > @maxlog AND step LIKE N'dwh.dim[_]%';
    SELECT @n_fact = COUNT(*) FROM ops.etl_log WHERE log_id > @maxlog AND step LIKE N'dwh.fact[_]%';

    IF @p_status IS NULL
        SELECT @res = 'FAIL', @det = N'Khong co dong step=pipeline trong ops.etl_log.';
    ELSE IF @p_status <> 'SUCCESS' OR @p_msg IS NOT NULL
        SELECT @res = 'FAIL', @det = CONCAT(N'pipeline status=', @p_status, N', msg=', @p_msg);
    ELSE IF @secs > 60
        SELECT @res = 'FAIL', @det = CONCAT(N'Qua cham: ', @secs, N's > 60s (DoD #4).');
    ELSE IF @p_loaded <= 0 OR @p_read < @p_loaded OR @p_rej <> @p_read - @p_loaded
        SELECT @res = 'FAIL', @det = CONCAT(N'So lieu pipeline sai: read/loaded/rejected=', @p_read, N'/', @p_loaded, N'/', @p_rej);
    ELSE IF @n_stg < 14 OR @n_dim < 6 OR @n_fact < 3
        SELECT @res = 'FAIL', @det = CONCAT(N'Thieu dong log buoc: stg/dim/fact=', @n_stg, N'/', @n_dim, N'/', @n_fact, N' (can >=14/6/3).');
    ELSE
        SET @det = CONCAT(N'pipeline ', @secs, N's; read/loaded/rejected=', @p_read, N'/', @p_loaded, N'/', @p_rej);
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-PIPE-02: chay lai -> du lieu khong doi (stg, dims, facts)
-- ------------------------------------------------------------------
DECLARE @a_fact NVARCHAR(MAX), @b_fact NVARCHAR(MAX), @a_dim NVARCHAR(MAX), @b_dim NVARCHAR(MAX);
DECLARE @a_stg_rows BIGINT, @a_stg_amt DECIMAL(38,6), @b_stg_rows BIGINT, @b_stg_amt DECIMAL(38,6);
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC ops.usp_fact_snapshot @snap = @a_fact OUTPUT;
    EXEC ops.usp_dim_snapshot  @snap = @a_dim  OUTPUT;
    EXEC ops.usp_stg_snapshot  @rows = @a_stg_rows OUTPUT, @amount_sum = @a_stg_amt OUTPUT;

    EXEC ops.usp_run_etl;

    EXEC ops.usp_fact_snapshot @snap = @b_fact OUTPUT;
    EXEC ops.usp_dim_snapshot  @snap = @b_dim  OUTPUT;
    EXEC ops.usp_stg_snapshot  @rows = @b_stg_rows OUTPUT, @amount_sum = @b_stg_amt OUTPUT;

    IF NOT (@a_fact IS NOT NULL AND @a_fact = @b_fact AND @a_dim = @b_dim
            AND @a_stg_rows = @b_stg_rows AND @a_stg_amt = @b_stg_amt)
        SELECT @res = 'FAIL', @det = N'Du lieu doi sau khi chay lai ETL.';
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-02', @res, @det);

-- ------------------------------------------------------------------
-- TC-PIPE-03: doi chieu src/stg/dwh khong con dong FAIL
-- ------------------------------------------------------------------
DECLARE @fc INT = NULL, @total INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC ops.usp_reconcile @failed_count = @fc OUTPUT, @quiet = 1;
    IF @fc IS NULL OR @fc <> 0
        SELECT @res = 'FAIL', @det = CONCAT(N'So kiem tra doi chieu that bai: ', @fc, N'. Chay EXEC ops.usp_reconcile; de xem.');
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-03', @res, @det);

-- ------------------------------------------------------------------
-- TC-PIPE-04: loi o giai doan stg -> THROW 50070, log pipeline FAILED, dims/facts KHONG chay
-- ------------------------------------------------------------------
DECLARE @thrown INT = NULL, @thrown_msg NVARCHAR(2000) = NULL, @late_dwh INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @maxlog = COALESCE(MAX(log_id), 0) FROM ops.etl_log;
    BEGIN TRY
        EXEC ops.usp_run_etl @simulate_fail_stage = 'stg';
    END TRY
    BEGIN CATCH
        SET @thrown = ERROR_NUMBER(); SET @thrown_msg = ERROR_MESSAGE();
    END CATCH;

    SET @p_status = NULL; SET @p_errno = NULL; SET @p_msg = NULL;
    SELECT TOP (1) @p_status = status, @p_errno = error_number, @p_msg = error_message
      FROM ops.etl_log WHERE step = N'pipeline' AND log_id > @maxlog ORDER BY log_id DESC;
    SELECT @late_dwh = COUNT(*) FROM ops.etl_log WHERE log_id > @maxlog AND step LIKE N'dwh.%';

    IF @thrown IS NULL
        SELECT @res = 'FAIL', @det = N'Khong nem loi khi gia lap loi stg.';
    ELSE IF @thrown <> 50070
        SELECT @res = 'FAIL', @det = CONCAT(N'Ma loi ', @thrown, N' <> 50070: ', @thrown_msg);
    ELSE IF @p_status IS NULL OR @p_status <> 'FAILED' OR @p_errno IS NULL OR @p_msg IS NULL OR @p_msg NOT LIKE N'%stg%'
        SELECT @res = 'FAIL', @det = CONCAT(N'Log pipeline sai: status=', @p_status, N', err=', @p_errno, N', msg=', @p_msg);
    ELSE IF @late_dwh <> 0
        SELECT @res = 'FAIL', @det = CONCAT(N'Giai doan dwh van chay sau khi stg loi: ', @late_dwh, N' dong log.');
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-04', @res, @det);

-- Nap lai sach sau TC-PIPE-04
BEGIN TRY
    EXEC ops.usp_run_etl;
END TRY
BEGIN CATCH
    PRINT N'CANH BAO: khong nap lai sach sau TC-PIPE-04: ' + ERROR_MESSAGE();
END CATCH;

-- ------------------------------------------------------------------
-- TC-PIPE-05: loi o giai doan facts -> fact rollback (xoa 1 dong truoc de chung minh), stg/dims da commit
-- ------------------------------------------------------------------
DECLARE @t_a NVARCHAR(MAX), @t_b NVARCHAR(MAX), @dims_ok INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    DELETE TOP (1) FROM dwh.fact_sales;               -- "pha" fact de chung minh rollback
    EXEC ops.usp_fact_snapshot @snap = @t_a OUTPUT;

    SELECT @maxlog = COALESCE(MAX(log_id), 0) FROM ops.etl_log;
    SET @thrown = NULL; SET @thrown_msg = NULL;
    BEGIN TRY
        EXEC ops.usp_run_etl @simulate_fail_stage = 'facts';
    END TRY
    BEGIN CATCH
        SET @thrown = ERROR_NUMBER(); SET @thrown_msg = ERROR_MESSAGE();
    END CATCH;

    EXEC ops.usp_fact_snapshot @snap = @t_b OUTPUT;
    SET @p_status = NULL; SET @p_msg = NULL;
    SELECT TOP (1) @p_status = status, @p_msg = error_message
      FROM ops.etl_log WHERE step = N'pipeline' AND log_id > @maxlog ORDER BY log_id DESC;
    SELECT @dims_ok = COUNT(*) FROM ops.etl_log
     WHERE log_id > @maxlog AND step LIKE N'dwh.dim[_]%' AND status = 'SUCCESS';

    IF @thrown IS NULL OR @thrown <> 50070
        SELECT @res = 'FAIL', @det = CONCAT(N'Loi mong doi 50070, nhan ', @thrown, N': ', @thrown_msg);
    ELSE IF @t_a <> @t_b
        SELECT @res = 'FAIL', @det = N'Fact bi thay doi du da loi -> rollback khong hoat dong.';
    ELSE IF @p_status IS NULL OR @p_status <> 'FAILED' OR @p_msg NOT LIKE N'%facts%'
        SELECT @res = 'FAIL', @det = CONCAT(N'Log pipeline sai: ', @p_status, N' / ', @p_msg);
    ELSE IF @dims_ok < 6
        SELECT @res = 'FAIL', @det = CONCAT(N'Dimension khong duoc commit truoc khi facts loi: ', @dims_ok, N'/6 buoc SUCCESS.');
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-05', @res, @det);

-- Nap lai sach sau TC-PIPE-05
BEGIN TRY
    EXEC ops.usp_run_etl;
END TRY
BEGIN CATCH
    PRINT N'CANH BAO: khong nap lai sach sau TC-PIPE-05: ' + ERROR_MESSAGE();
END CATCH;

-- ------------------------------------------------------------------
-- TC-PIPE-06: tham so sai -> THROW 50070 (boc 50072) va log FAILED, khong dong nao bi nap
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @maxlog = COALESCE(MAX(log_id), 0) FROM ops.etl_log;
    SET @thrown = NULL; SET @thrown_msg = NULL;
    BEGIN TRY
        EXEC ops.usp_run_etl @simulate_fail_stage = 'xyz';
    END TRY
    BEGIN CATCH
        SET @thrown = ERROR_NUMBER(); SET @thrown_msg = ERROR_MESSAGE();
    END CATCH;

    SET @p_status = NULL; SET @p_errno = NULL;
    SELECT TOP (1) @p_status = status, @p_errno = error_number
      FROM ops.etl_log WHERE step = N'pipeline' AND log_id > @maxlog ORDER BY log_id DESC;
    SELECT @late_dwh = COUNT(*) FROM ops.etl_log WHERE log_id > @maxlog AND step <> N'pipeline';

    IF @thrown IS NULL OR @thrown <> 50070
        SELECT @res = 'FAIL', @det = CONCAT(N'Loi mong doi 50070, nhan ', @thrown, N': ', @thrown_msg);
    ELSE IF @p_status IS NULL OR @p_status <> 'FAILED' OR @p_errno <> 50072
        SELECT @res = 'FAIL', @det = CONCAT(N'Log pipeline sai: status=', @p_status, N', err=', @p_errno, N' (can FAILED/50072)');
    ELSE IF @late_dwh <> 0
        SELECT @res = 'FAIL', @det = CONCAT(N'Co giai doan chay du tham so sai: ', @late_dwh, N' dong log.');
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-06', @res, @det);

-- ------------------------------------------------------------------
-- TC-PIPE-07: doi chieu bat duoc du lieu bi sua (sua gross_profit trong transaction roi hoan tac)
-- ------------------------------------------------------------------
DECLARE @fc_bad INT = NULL, @fc_after INT = NULL;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    BEGIN TRANSACTION;
        UPDATE TOP (1) dwh.fact_sales SET gross_profit = gross_profit + 1;
        EXEC ops.usp_reconcile @failed_count = @fc_bad OUTPUT, @quiet = 1;
    ROLLBACK TRANSACTION;

    EXEC ops.usp_reconcile @failed_count = @fc_after OUTPUT, @quiet = 1;

    IF @fc_bad IS NULL OR @fc_bad < 1
        SELECT @res = 'FAIL', @det = N'Doi chieu khong phat hien gross_profit bi sua.';
    ELSE IF @fc_after IS NULL OR @fc_after <> 0
        SELECT @res = 'FAIL', @det = CONCAT(N'Sau rollback doi chieu van loi: ', @fc_after);
END TRY
BEGIN CATCH
    IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PIPE-07', @res, @det);

-- ------------------------------------------------------------------
-- Ket qua
-- ------------------------------------------------------------------
SELECT test_id, result, detail FROM #r ORDER BY test_id;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed,
       SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END) AS failed
  FROM #r;
