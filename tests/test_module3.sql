/* =====================================================================
   tests/test_module3.sql
   Bao phu: TC-PRE-02, TC-FACT-01, TC-FACT-02, TC-FACT-03, TC-DQ-01-DWH, TC-DQ-02-DWH,
            TC-DQ-04, TC-MOD-01, TC-ETL-03, TC-ETL-04, TC-ETL-05
   Chay SAU 01..05. Ket qua: bang PASS/FAIL o cuoi script.
   Script tu nap lai stg, dimension va fact nhieu lan; co 2 buoc "pha" du lieu stg/fact de kiem chung
   (TC-ETL-03, TC-FACT-03). Cuoi moi buoc deu don dep va nap lai de tra ve trang thai sach.
   ===================================================================== */
USE FinanceDW;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF OBJECT_ID(N'tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (test_id VARCHAR(20) NOT NULL, result VARCHAR(4) NOT NULL, detail NVARCHAR(1000) NULL);

DECLARE @res VARCHAR(4);
DECLARE @det NVARCHAR(1000);
DECLARE @run UNIQUEIDENTIFIER;

-- ------------------------------------------------------------------
-- TC-PRE-02: dieu kien dau vao - nap stg, dimension, fact thanh cong
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC stg.usp_load_all;
    EXEC dwh.usp_load_dims;
    EXEC dwh.usp_load_facts;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PRE-02', @res, @det);

-- ------------------------------------------------------------------
-- TC-FACT-01: chay 2 lan -> fact khong doi (so dong, tong tien, noi dung); 4 buoc log deu SUCCESS
-- ------------------------------------------------------------------
DECLARE @s1 NVARCHAR(MAX), @s2 NVARCHAR(MAX), @f1_steps INT, @f1_ok INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC dwh.usp_load_facts;
    EXEC ops.usp_fact_snapshot @snap = @s1 OUTPUT;
    EXEC dwh.usp_load_facts;
    EXEC ops.usp_fact_snapshot @snap = @s2 OUTPUT;

    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @f1_steps = COUNT(*), @f1_ok = SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END)
      FROM ops.etl_log WHERE run_id = @run;

    IF NOT (@s1 IS NOT NULL AND @s1 = @s2 AND @f1_steps = 4 AND @f1_ok = 4)
    BEGIN
        SET @res = 'FAIL';
        SET @det = LEFT(CONCAT(N'snapshot giong nhau=', CASE WHEN @s1 = @s2 THEN N'co' ELSE N'KHONG' END,
                               N'; so buoc/SUCCESS=', @f1_steps, N'/', @f1_ok, N'; s1=', @s1, N'; s2=', @s2), 1000);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-FACT-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-01-DWH: doi chieu tong tien nguon vs fact (chenh lech = 0)
-- ------------------------------------------------------------------
DECLARE @rv_src DECIMAL(38,6), @rv_dwh DECIMAL(38,6);
DECLARE @pu_src DECIMAL(38,6), @pu_dwh DECIMAL(38,6);
DECLARE @qt_src DECIMAL(38,6), @qt_dwh DECIMAL(38,6);
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @rv_src = SUM(CAST(LineTotal AS DECIMAL(38,6)))    FROM src.Sales_SalesOrderDetail;
    SELECT @rv_dwh = SUM(CAST(revenue AS DECIMAL(38,6)))      FROM dwh.fact_sales;
    SELECT @pu_src = SUM(CAST(LineTotal AS DECIMAL(38,6)))    FROM src.Purchasing_PurchaseOrderDetail;
    SELECT @pu_dwh = SUM(CAST(line_total AS DECIMAL(38,6)))   FROM dwh.fact_purchasing;
    SELECT @qt_src = SUM(CAST(SalesQuota AS DECIMAL(38,6)))   FROM src.Sales_SalesPersonQuotaHistory;
    SELECT @qt_dwh = SUM(CAST(quota_amount AS DECIMAL(38,6))) FROM dwh.fact_quota;

    IF NOT (@rv_src IS NOT NULL AND @rv_src = @rv_dwh AND @pu_src IS NOT NULL AND @pu_src = @pu_dwh
            AND @qt_src IS NOT NULL AND @qt_src = @qt_dwh)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'revenue nguon/dwh=', @rv_src, N'/', @rv_dwh,
                          N'; purchasing=', @pu_src, N'/', @pu_dwh,
                          N'; quota=', @qt_src, N'/', @qt_dwh);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-01-DWH', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-02-DWH: so dong nguon = so dong fact (du lieu sach -> khong dong nao bi tu choi)
-- ------------------------------------------------------------------
DECLARE @cs_src BIGINT, @cs BIGINT, @cp_src BIGINT, @cp BIGINT, @cq_src BIGINT, @cq BIGINT, @rej_all INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @cs_src = COUNT_BIG(*) FROM src.Sales_SalesOrderDetail;
    SELECT @cs     = COUNT_BIG(*) FROM dwh.fact_sales;
    SELECT @cp_src = COUNT_BIG(*) FROM src.Purchasing_PurchaseOrderDetail;
    SELECT @cp     = COUNT_BIG(*) FROM dwh.fact_purchasing;
    SELECT @cq_src = COUNT_BIG(*) FROM src.Sales_SalesPersonQuotaHistory;
    SELECT @cq     = COUNT_BIG(*) FROM dwh.fact_quota;
    SELECT @rej_all = COUNT(*) FROM ops.reject WHERE run_id = @run;

    IF NOT (@cs_src > 0 AND @cs_src = @cs AND @cp_src > 0 AND @cp_src = @cp AND @cq_src > 0 AND @cq_src = @cq AND @rej_all = 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = LEFT(CONCAT(N'nguon/fact: sales ', @cs_src, N'/', @cs, N'; purchasing ', @cp_src, N'/', @cp,
                               N'; quota ', @cq_src, N'/', @cq, N'; dong bi tu choi o lan nap gan nhat=', @rej_all,
                               N'; ly do: ',
                               COALESCE((SELECT STRING_AGG(x.reason + N' x' + CAST(x.n AS NVARCHAR(20)), N', ')
                                           FROM (SELECT reason, COUNT(*) AS n FROM ops.reject WHERE run_id = @run GROUP BY reason) AS x), N'(khong co)')), 1000);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-02-DWH', @res, @det);

-- ------------------------------------------------------------------
-- TC-MOD-01: khong co khoa ngoai mo coi; 10 khoa ngoai ton tai, bat, duoc tin cay
-- ------------------------------------------------------------------
DECLARE @orphans INT, @fk_n INT, @fk_untrusted INT, @fk_disabled INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @orphans =
          (SELECT COUNT(*) FROM dwh.fact_sales f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date        d WHERE d.date_key        = f.date_key))
        + (SELECT COUNT(*) FROM dwh.fact_sales f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_product     d WHERE d.product_key     = f.product_key))
        + (SELECT COUNT(*) FROM dwh.fact_sales f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_customer    d WHERE d.customer_key    = f.customer_key))
        + (SELECT COUNT(*) FROM dwh.fact_sales f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_territory   d WHERE d.territory_key   = f.territory_key))
        + (SELECT COUNT(*) FROM dwh.fact_sales f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_salesperson d WHERE d.salesperson_key = f.salesperson_key))
        + (SELECT COUNT(*) FROM dwh.fact_purchasing f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date    d WHERE d.date_key       = f.date_key))
        + (SELECT COUNT(*) FROM dwh.fact_purchasing f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_product d WHERE d.product_key     = f.product_key))
        + (SELECT COUNT(*) FROM dwh.fact_purchasing f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_vendor  d WHERE d.vendor_key      = f.vendor_key))
        + (SELECT COUNT(*) FROM dwh.fact_quota f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_salesperson  d WHERE d.salesperson_key = f.salesperson_key))
        + (SELECT COUNT(*) FROM dwh.fact_quota f WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date         d WHERE d.date_key        = f.date_key));

    SELECT @fk_n         = COUNT(*),
           @fk_untrusted = SUM(CAST(is_not_trusted AS INT)),
           @fk_disabled  = SUM(CAST(is_disabled AS INT))
      FROM sys.foreign_keys
     WHERE parent_object_id IN (OBJECT_ID(N'dwh.fact_sales'), OBJECT_ID(N'dwh.fact_purchasing'), OBJECT_ID(N'dwh.fact_quota'));

    IF NOT (@orphans = 0 AND @fk_n = 10 AND @fk_untrusted = 0 AND @fk_disabled = 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'mo coi=', @orphans, N'; so FK=', @fk_n, N' (can 10); khong tin cay=', @fk_untrusted, N'; bi tat=', @fk_disabled);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-MOD-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-ETL-04: don khong co nhan vien ban (SalesPersonID NULL) -> key -1, khong mat dong
-- ------------------------------------------------------------------
DECLARE @exp_noperson INT, @act_noperson INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @exp_noperson = COUNT(*)
      FROM stg.SalesOrderDetail AS d
      JOIN stg.SalesOrderHeader AS h ON h.SalesOrderID = d.SalesOrderID
     WHERE h.SalesPersonID IS NULL;
    SELECT @act_noperson = COUNT(*) FROM dwh.fact_sales WHERE salesperson_key = -1;

    IF NOT (@exp_noperson > 0 AND @exp_noperson = @act_noperson)
    BEGIN
        SET @res = 'FAIL'; SET @det = CONCAT(N'ky vong=', @exp_noperson, N'; thuc te=', @act_noperson);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ETL-04', @res, @det);

-- ------------------------------------------------------------------
-- TC-ETL-05: gia von - so dong FALLBACK dung va co trong log; tong COGS khop tinh doc lap
-- ------------------------------------------------------------------
DECLARE @exp_fb INT, @act_fb INT, @log_fb INT, @cogs_exp DECIMAL(38,6), @cogs_act DECIMAL(38,6);
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC dwh.usp_load_facts;                       -- lan nap sach gan nhat, de doc dong log thong tin
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;

    SELECT @exp_fb = COUNT(*)
      FROM stg.SalesOrderDetail AS d
      JOIN stg.SalesOrderHeader AS h ON h.SalesOrderID = d.SalesOrderID
     WHERE NOT EXISTS (SELECT 1 FROM stg.ProductCostHistory AS ch
                        WHERE ch.ProductID = d.ProductID
                          AND ch.StartDate <= h.OrderDate
                          AND (ch.EndDate IS NULL OR ch.EndDate >= h.OrderDate));

    SELECT @act_fb = COUNT(*) FROM dwh.fact_sales WHERE cogs_source = 'FALLBACK';
    SELECT @log_fb = rows_loaded FROM ops.etl_log WHERE run_id = @run AND step = N'dwh.fact_sales[cogs_fallback]';

    -- Tinh doc lap: dong lich su co StartDate lon nhat trong cac dong con hieu luc tai ngay dat hang
    -- (T-SQL khong cho SUM tren bieu thuc co subquery -> tinh tung dong trong bang dan xuat roi moi cong)
    SELECT @cogs_exp = SUM(CAST(x.line_cogs AS DECIMAL(38,6)))
      FROM (SELECT d.OrderQty * COALESCE(
                       (SELECT ch.StandardCost
                          FROM stg.ProductCostHistory AS ch
                         WHERE ch.ProductID = d.ProductID
                           AND ch.StartDate = (SELECT MAX(c2.StartDate)
                                                 FROM stg.ProductCostHistory AS c2
                                                WHERE c2.ProductID = d.ProductID
                                                  AND c2.StartDate <= h.OrderDate
                                                  AND (c2.EndDate IS NULL OR c2.EndDate >= h.OrderDate))),
                       pr.StandardCost) AS line_cogs
              FROM stg.SalesOrderDetail AS d
              JOIN stg.SalesOrderHeader AS h  ON h.SalesOrderID = d.SalesOrderID
              JOIN stg.Product          AS pr ON pr.ProductID   = d.ProductID) AS x;

    SELECT @cogs_act = SUM(CAST(cogs AS DECIMAL(38,6))) FROM dwh.fact_sales;

    IF NOT (@exp_fb = @act_fb AND @act_fb = @log_fb AND @cogs_exp = @cogs_act)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'FALLBACK ky vong/thuc te/log=', @exp_fb, N'/', @act_fb, N'/', @log_fb,
                          N'; COGS ky vong/thuc te=', @cogs_exp, N'/', @cogs_act);
    END
    ELSE
    BEGIN
        SET @det = CONCAT(N'(thong tin) so dong dung gia von du phong FALLBACK = ', @act_fb);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ETL-05', @res, @det);

-- ------------------------------------------------------------------
-- TC-FACT-02: dang thuc ke toan - revenue + discount = qty * don gia; gross_profit = revenue - cogs;
--             moi dong fact doi chieu duoc voi dong chi tiet nguon
-- ------------------------------------------------------------------
DECLARE @bad_calc INT, @joined INT, @total_fact INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @bad_calc = COUNT(*),
           @joined   = COUNT(*)
      FROM dwh.fact_sales AS f
      JOIN stg.SalesOrderDetail AS d
        ON d.SalesOrderID = f.sales_order_id AND d.SalesOrderDetailID = f.sales_order_detail_id
     WHERE f.revenue + f.discount_amt <> CAST(d.OrderQty * d.UnitPrice AS DECIMAL(19,6))
        OR f.gross_profit <> f.revenue - f.cogs
        OR f.order_qty <> d.OrderQty;

    SELECT @joined = COUNT(*)
      FROM dwh.fact_sales AS f
      JOIN stg.SalesOrderDetail AS d
        ON d.SalesOrderID = f.sales_order_id AND d.SalesOrderDetailID = f.sales_order_detail_id;
    SELECT @total_fact = COUNT(*) FROM dwh.fact_sales;

    IF NOT (@bad_calc = 0 AND @joined = @total_fact AND @total_fact > 0)
    BEGIN
        SET @res = 'FAIL'; SET @det = CONCAT(N'dong sai cong thuc=', @bad_calc, N'; dong doi chieu duoc/tong=', @joined, N'/', @total_fact);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-FACT-02', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-04: Quota va Actual cung grain quy x nhan vien, co co ro rang (view dwh.vw_quota_vs_actual)
-- ------------------------------------------------------------------
DECLARE @q_view DECIMAL(38,6), @q_fact DECIMAL(38,6), @a_view DECIMAL(38,6), @a_fact DECIMAL(38,6);
DECLARE @no_flag INT, @dup_grain INT, @quota_only INT, @actual_only INT, @both INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @q_view = SUM(CAST(quota_amount AS DECIMAL(38,6))),
           @a_view = SUM(CAST(actual_revenue AS DECIMAL(38,6))),
           @no_flag     = SUM(CASE WHEN has_quota = 0 AND has_actual = 0 THEN 1 ELSE 0 END),
           @quota_only  = SUM(CASE WHEN has_quota = 1 AND has_actual = 0 THEN 1 ELSE 0 END),
           @actual_only = SUM(CASE WHEN has_quota = 0 AND has_actual = 1 THEN 1 ELSE 0 END),
           @both        = SUM(CASE WHEN has_quota = 1 AND has_actual = 1 THEN 1 ELSE 0 END)
      FROM dwh.vw_quota_vs_actual;
    SELECT @q_fact = SUM(CAST(quota_amount AS DECIMAL(38,6))) FROM dwh.fact_quota;
    SELECT @a_fact = SUM(CAST(revenue AS DECIMAL(38,6))) FROM dwh.fact_sales WHERE salesperson_key <> -1;
    SELECT @dup_grain = COUNT(*) FROM (
        SELECT salesperson_key, quarter_start_date_key
          FROM dwh.vw_quota_vs_actual
         GROUP BY salesperson_key, quarter_start_date_key
        HAVING COUNT(*) > 1) AS x;

    IF NOT (@q_view = @q_fact AND @a_view = @a_fact AND @no_flag = 0 AND @dup_grain = 0 AND @both > 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'quota view/fact=', @q_view, N'/', @q_fact, N'; actual view/fact=', @a_view, N'/', @a_fact,
                          N'; dong khong co co=', @no_flag, N'; trung grain=', @dup_grain, N'; ca hai=', @both);
    END
    ELSE
    BEGIN
        SET @det = CONCAT(N'(thong tin) quy co ca quota va actual=', @both, N'; chi co quota=', @quota_only, N'; chi co actual=', @actual_only);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-04', @res, @det);

-- ------------------------------------------------------------------
-- TC-ETL-03: dong loi di vao ops.reject, ETL van chay tiep, rows_rejected dung
-- Them 2 dong chi tiet gia vao stg: (1) khong co header, (2) so tien vuot DECIMAL(19,6)
-- ------------------------------------------------------------------
DECLARE @clean_cnt INT, @prod_id INT, @hdr_id INT, @after_cnt INT;
DECLARE @n_rej INT, @key_ok INT, @log_rej INT, @log_read INT, @log_loaded INT, @log_status VARCHAR(12);
SET @res = 'FAIL'; SET @det = N'khong chay duoc';
BEGIN TRY
    EXEC dwh.usp_load_facts;                                         -- nen sach
    SELECT @clean_cnt = COUNT(*) FROM dwh.fact_sales;
    SELECT @prod_id = MIN(ProductID)    FROM stg.Product;
    SELECT @hdr_id  = MIN(SalesOrderID) FROM stg.SalesOrderHeader;

    INSERT INTO stg.SalesOrderDetail (SalesOrderID, SalesOrderDetailID, OrderQty, ProductID, SpecialOfferID,
                                      UnitPrice, UnitPriceDiscount, LineTotal, etl_run_id)
    VALUES (-999001, 1,      1, @prod_id, 1, 10,                     0, 10,                     NEWID()),
           (@hdr_id, 999999, 1, @prod_id, 1, 99999999999999.0000,    0, 99999999999999.000000,  NEWID());

    EXEC dwh.usp_load_facts;                                         -- phai van thanh cong
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;

    SELECT @after_cnt = COUNT(*) FROM dwh.fact_sales;
    SELECT @n_rej = COUNT(*) FROM ops.reject WHERE run_id = @run;
    SELECT @key_ok = COUNT(*) FROM ops.reject
     WHERE run_id = @run
       AND ((source_key = N'-999001/1' AND reason = N'ORPHAN_HEADER')
         OR (source_key = CONCAT(@hdr_id, N'/999999') AND reason = N'AMOUNT_OUT_OF_RANGE'));
    SELECT @log_rej = rows_rejected, @log_read = rows_read, @log_loaded = rows_loaded, @log_status = status
      FROM ops.etl_log WHERE run_id = @run AND step = N'dwh.fact_sales';

    IF @n_rej = 2 AND @key_ok = 2 AND @log_rej = 2 AND @log_read = @log_loaded + @log_rej
       AND @log_status = 'SUCCESS' AND @after_cnt = @clean_cnt
    BEGIN
        SET @res = 'PASS'; SET @det = NULL;
    END
    ELSE
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'reject=', @n_rej, N' (dung ly do/khoa=', @key_ok, N'); log rejected=', @log_rej,
                          N'; doc/nap=', @log_read, N'/', @log_loaded, N'; trang thai=', @log_status,
                          N'; fact truoc/sau=', @clean_cnt, N'/', @after_cnt);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-ETL-03', @res, @det);

-- Don dep sau TC-ETL-03 (luon chay, ke ca khi test o tren loi)
DELETE FROM stg.SalesOrderDetail
 WHERE (SalesOrderID = -999001 AND SalesOrderDetailID = 1) OR SalesOrderDetailID = 999999;
IF @run IS NOT NULL DELETE FROM ops.reject WHERE run_id = @run;
BEGIN TRY
    EXEC dwh.usp_load_facts;
END TRY
BEGIN CATCH
    PRINT N'CANH BAO: khong nap lai fact sach sau TC-ETL-03: ' + ERROR_MESSAGE();
END CATCH;

-- ------------------------------------------------------------------
-- TC-FACT-03: loi gia lap giua chung -> ROLLBACK (ke ca ops.reject) + log dung
-- Kiem chung ROLLBACK: xoa 1 dong fact_sales (fact bi TRUNCATE roi nap lai TRONG transaction).
-- Neu da commit, lan nap lai se tra dong do ve. Con thieu 1 dong = da rollback.
-- Them 1 dong chi tiet mo coi vao stg de proc phat sinh reject trong transaction; reject nay phai bi rollback.
-- ------------------------------------------------------------------
DECLARE @f3_before INT, @f3_after INT, @f3_caught BIT, @f3_err INT, @f3_prod INT;
DECLARE @f3_failed INT, @f3_success INT, @f3_rolled INT, @f3_rej_kept INT;
SET @res = 'FAIL'; SET @det = N'khong chay duoc';
SET @f3_caught = 0;
BEGIN TRY
    EXEC dwh.usp_load_facts;                                         -- nen sach
    DELETE TOP (1) FROM dwh.fact_sales;
    SELECT @f3_before = COUNT(*) FROM dwh.fact_sales;

    SELECT @f3_prod = MIN(ProductID) FROM stg.Product;
    INSERT INTO stg.SalesOrderDetail (SalesOrderID, SalesOrderDetailID, OrderQty, ProductID, SpecialOfferID,
                                      UnitPrice, UnitPriceDiscount, LineTotal, etl_run_id)
    VALUES (-999001, 1, 1, @f3_prod, 1, 10, 0, 10, NEWID());

    BEGIN TRY
        EXEC dwh.usp_load_facts @simulate_fail_after = N'fact_quota';
    END TRY
    BEGIN CATCH
        SET @f3_caught = 1; SET @f3_err = ERROR_NUMBER();
    END CATCH;

    SELECT @f3_after = COUNT(*) FROM dwh.fact_sales;
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @f3_failed  = SUM(CASE WHEN status = 'FAILED'      THEN 1 ELSE 0 END),
           @f3_success = SUM(CASE WHEN status = 'SUCCESS'     THEN 1 ELSE 0 END),
           @f3_rolled  = SUM(CASE WHEN status = 'ROLLED_BACK' THEN 1 ELSE 0 END)
      FROM ops.etl_log WHERE run_id = @run;
    SELECT @f3_rej_kept = COUNT(*) FROM ops.reject WHERE run_id = @run;

    IF @f3_caught = 1 AND @f3_err = 50060 AND @f3_after = @f3_before
       AND @f3_failed = 1 AND @f3_success = 0 AND @f3_rolled >= 1 AND @f3_rej_kept = 0
    BEGIN
        SET @res = 'PASS'; SET @det = NULL;
    END
    ELSE
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'caught=', @f3_caught, N', err=', @f3_err, N', fact truoc/sau=', @f3_before, N'/', @f3_after,
                          N', FAILED/SUCCESS/ROLLED_BACK=', @f3_failed, N'/', @f3_success, N'/', @f3_rolled,
                          N', reject con lai=', @f3_rej_kept);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-FACT-03', @res, @det);

-- Don dep sau TC-FACT-03
DELETE FROM stg.SalesOrderDetail WHERE SalesOrderID = -999001 AND SalesOrderDetailID = 1;
BEGIN TRY
    EXEC dwh.usp_load_facts;
END TRY
BEGIN CATCH
    PRINT N'CANH BAO: khong nap lai fact sach sau TC-FACT-03: ' + ERROR_MESSAGE();
END CATCH;

-- ------------------------------------------------------------------
-- Ket qua
-- ------------------------------------------------------------------
SELECT test_id, result, detail FROM #r ORDER BY test_id;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed,
       SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END) AS failed
  FROM #r;
