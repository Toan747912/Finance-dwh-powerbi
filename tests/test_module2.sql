/* =====================================================================
   tests/test_module2.sql
   Bao phu: TC-DIM-01..05, TC-DQ-03, TC-DQ-03b, TC-MOD-02 (+ TC-PRE-01 dieu kien dau vao)
   Chay SAU 01, 02, 03, 04. Ket qua: bang PASS/FAIL o cuoi script.
   Script tu nap lai stg, nap dimension nhieu lan, co ca buoc "pha" du lieu de kiem chung
   (dung 1 dong dimension roi chay lai proc) - cuoi moi buoc deu nap lai de tra ve trang thai sach.
   ===================================================================== */
USE FinanceDW;
SET NOCOUNT ON;
SET XACT_ABORT OFF;

IF OBJECT_ID(N'tempdb..#r') IS NOT NULL DROP TABLE #r;
CREATE TABLE #r (test_id VARCHAR(20) NOT NULL, result VARCHAR(4) NOT NULL, detail NVARCHAR(1000) NULL);

DECLARE @res VARCHAR(4);
DECLARE @det NVARCHAR(1000);

-- ------------------------------------------------------------------
-- TC-PRE-01: dieu kien dau vao - nap stg thanh cong
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC stg.usp_load_all;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-PRE-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-DIM-01: chay 2 lan -> dimension khong doi (so dong, noi dung, khoa thay the),
--            lan 2 khong insert/update dong nao, ca 6 buoc SUCCESS
-- ------------------------------------------------------------------
DECLARE @s1 NVARCHAR(MAX), @s2 NVARCHAR(MAX), @run UNIQUEIDENTIFIER;
DECLARE @sum_loaded INT, @n_steps INT, @n_ok INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    EXEC dwh.usp_load_dims;
    EXEC ops.usp_dim_snapshot @snap = @s1 OUTPUT;
    EXEC dwh.usp_load_dims;
    EXEC ops.usp_dim_snapshot @snap = @s2 OUTPUT;

    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @sum_loaded = SUM(rows_loaded),
           @n_steps    = COUNT(*),
           @n_ok       = SUM(CASE WHEN status = 'SUCCESS' THEN 1 ELSE 0 END)
      FROM ops.etl_log WHERE run_id = @run;

    IF NOT (@s1 IS NOT NULL AND @s1 = @s2 AND @sum_loaded = 0 AND @n_steps = 6 AND @n_ok = 6)
    BEGIN
        SET @res = 'FAIL';
        SET @det = LEFT(N'snapshot giong nhau=' + CASE WHEN @s1 = @s2 THEN N'co' ELSE N'KHONG' END
                      + N'; lan2 loaded=' + COALESCE(CAST(@sum_loaded AS NVARCHAR(20)), N'NULL')
                      + N'; so buoc/SUCCESS=' + COALESCE(CAST(@n_steps AS NVARCHAR(20)), N'NULL') + N'/' + COALESCE(CAST(@n_ok AS NVARCHAR(20)), N'NULL')
                      + N'; s1=' + COALESCE(@s1, N'NULL') + N'; s2=' + COALESCE(@s2, N'NULL'), 1000);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DIM-01', @res, @det);

-- ------------------------------------------------------------------
-- TC-DIM-02: moi dimension (tru dim_date) co dung 1 dong Unknown key = -1;
--            dim_date KHONG co dong am
-- ------------------------------------------------------------------
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    IF NOT (   (SELECT COUNT(*) FROM dwh.dim_product     WHERE product_key     = -1 AND product_id         = -1) = 1
           AND (SELECT COUNT(*) FROM dwh.dim_customer    WHERE customer_key    = -1 AND customer_id        = -1) = 1
           AND (SELECT COUNT(*) FROM dwh.dim_territory   WHERE territory_key   = -1 AND territory_id       = -1) = 1
           AND (SELECT COUNT(*) FROM dwh.dim_salesperson WHERE salesperson_key = -1 AND business_entity_id = -1) = 1
           AND (SELECT COUNT(*) FROM dwh.dim_vendor      WHERE vendor_key      = -1 AND vendor_id          = -1) = 1
           AND NOT EXISTS (SELECT 1 FROM dwh.dim_date WHERE date_key < 0))
    BEGIN
        SET @res = 'FAIL'; SET @det = N'thieu/du dong Unknown, hoac dim_date co key am';
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DIM-02', @res, @det);

-- ------------------------------------------------------------------
-- TC-DIM-03: moi khoa tu nhien o nguon deu co dong trong dimension
--            (so dong dimension khong tinh Unknown = so dong stg)
-- ------------------------------------------------------------------
DECLARE @dp INT, @sp INT, @dc INT, @sc INT, @dt INT, @st INT, @ds INT, @ss INT, @dv INT, @sv INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @dp = COUNT(*) FROM dwh.dim_product     WHERE product_key     > 0;
    SELECT @sp = COUNT(*) FROM stg.Product;
    SELECT @dc = COUNT(*) FROM dwh.dim_customer    WHERE customer_key    > 0;
    SELECT @sc = COUNT(*) FROM stg.Customer;
    SELECT @dt = COUNT(*) FROM dwh.dim_territory   WHERE territory_key   > 0;
    SELECT @st = COUNT(*) FROM stg.SalesTerritory;
    SELECT @ds = COUNT(*) FROM dwh.dim_salesperson WHERE salesperson_key > 0;
    SELECT @ss = COUNT(*) FROM stg.SalesPerson;
    SELECT @dv = COUNT(*) FROM dwh.dim_vendor      WHERE vendor_key      > 0;
    SELECT @sv = COUNT(*) FROM stg.Vendor;

    IF NOT (@sp > 0 AND @dp = @sp AND @dc = @sc AND @dt = @st AND @ds = @ss AND @dv = @sv)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'dim/stg: product ', @dp, N'/', @sp, N'; customer ', @dc, N'/', @sc,
                          N'; territory ', @dt, N'/', @st, N'; salesperson ', @ds, N'/', @ss, N'; vendor ', @dv, N'/', @sv);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DIM-03', @res, @det);

-- ------------------------------------------------------------------
-- TC-MOD-02: khong trung khoa thay the, khong trung khoa tu nhien trong moi dimension
-- ------------------------------------------------------------------
DECLARE @dups INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @dups = COUNT(*) FROM (
        SELECT date_key AS k FROM dwh.dim_date GROUP BY date_key HAVING COUNT(*) > 1
        UNION ALL SELECT DATEDIFF(DAY, CAST('19000101' AS DATE), full_date) FROM dwh.dim_date GROUP BY full_date HAVING COUNT(*) > 1
        UNION ALL SELECT product_key FROM dwh.dim_product GROUP BY product_key HAVING COUNT(*) > 1
        UNION ALL SELECT product_id FROM dwh.dim_product GROUP BY product_id HAVING COUNT(*) > 1
        UNION ALL SELECT customer_key FROM dwh.dim_customer GROUP BY customer_key HAVING COUNT(*) > 1
        UNION ALL SELECT customer_id FROM dwh.dim_customer GROUP BY customer_id HAVING COUNT(*) > 1
        UNION ALL SELECT territory_key FROM dwh.dim_territory GROUP BY territory_key HAVING COUNT(*) > 1
        UNION ALL SELECT territory_id FROM dwh.dim_territory GROUP BY territory_id HAVING COUNT(*) > 1
        UNION ALL SELECT salesperson_key FROM dwh.dim_salesperson GROUP BY salesperson_key HAVING COUNT(*) > 1
        UNION ALL SELECT business_entity_id FROM dwh.dim_salesperson GROUP BY business_entity_id HAVING COUNT(*) > 1
        UNION ALL SELECT vendor_key FROM dwh.dim_vendor GROUP BY vendor_key HAVING COUNT(*) > 1
        UNION ALL SELECT vendor_id FROM dwh.dim_vendor GROUP BY vendor_id HAVING COUNT(*) > 1
    ) AS x;
    IF @dups <> 0
    BEGIN
        SET @res = 'FAIL'; SET @det = N'so nhom khoa bi trung = ' + CAST(@dups AS NVARCHAR(20));
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-MOD-02', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-03: dim_date lien tuc, phu moi ngay cua fact, date_key dung dinh dang yyyymmdd
-- ------------------------------------------------------------------
DECLARE @dn INT, @dmin DATE, @dmax DATE, @smin DATE, @smax DATE, @bad_key INT, @miss INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @dn = COUNT(*), @dmin = MIN(full_date), @dmax = MAX(full_date) FROM dwh.dim_date;

    SELECT @smin = MIN(x.d), @smax = MAX(x.d)
      FROM (SELECT CAST(OrderDate AS DATE) AS d FROM stg.SalesOrderHeader
            UNION ALL SELECT CAST(OrderDate AS DATE) FROM stg.PurchaseOrderHeader
            UNION ALL SELECT CAST(QuotaDate AS DATE) FROM stg.SalesPersonQuotaHistory) AS x;

    SELECT @bad_key = COUNT(*) FROM dwh.dim_date
     WHERE date_key <> YEAR(full_date) * 10000 + MONTH(full_date) * 100 + DAY(full_date);

    SELECT @miss =
          (SELECT COUNT(*) FROM stg.SalesOrderHeader h
            WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.full_date = CAST(h.OrderDate AS DATE)))
        + (SELECT COUNT(*) FROM stg.PurchaseOrderHeader h
            WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.full_date = CAST(h.OrderDate AS DATE)))
        + (SELECT COUNT(*) FROM stg.SalesPersonQuotaHistory q
            WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date d WHERE d.full_date = CAST(q.QuotaDate AS DATE)));

    IF NOT (@dn > 0 AND @dn = DATEDIFF(DAY, @dmin, @dmax) + 1
            AND @dmin <= @smin AND @dmax >= @smax AND @bad_key = 0 AND @miss = 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'so ngay=', @dn, N'; khoang ', CONVERT(CHAR(10), @dmin, 23), N'..', CONVERT(CHAR(10), @dmax, 23),
                          N'; khoang fact ', CONVERT(CHAR(10), @smin, 23), N'..', CONVERT(CHAR(10), @smax, 23),
                          N'; date_key sai=', @bad_key, N'; ngay fact thieu trong dim=', @miss);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-03', @res, @det);

-- ------------------------------------------------------------------
-- TC-DQ-03b: co ky chua tron ven hop ly (kiem tra doc lap voi cong thuc trong proc)
--   - is_year_complete dong nhat trong tung nam
--   - nam danh dau tron ven <=> du lieu ban hang co du 12 thang trong nam do
--     (dung voi bo AdventureWorks: du lieu bat dau giua nam dau, ket thuc giua nam cuoi)
--   - thang danh dau tron ven thi thang do phai co don hang
-- ------------------------------------------------------------------
DECLARE @bad_year INT, @bad_month INT;
SET @res = 'PASS'; SET @det = NULL;
BEGIN TRY
    SELECT @bad_year = COUNT(*) FROM (
        SELECT dd.[year] AS y,
               MIN(CAST(dd.is_year_complete AS INT)) AS mn,
               MAX(CAST(dd.is_year_complete AS INT)) AS mx,
               (SELECT COUNT(DISTINCT MONTH(h.OrderDate)) FROM stg.SalesOrderHeader AS h WHERE YEAR(h.OrderDate) = dd.[year]) AS months_with_orders
          FROM dwh.dim_date AS dd
         GROUP BY dd.[year]
    ) AS t
    WHERE mn <> mx
       OR (mx = 1 AND months_with_orders <> 12)
       OR (mx = 0 AND months_with_orders = 12);

    SELECT @bad_month = COUNT(*) FROM dwh.dim_date AS d
     WHERE d.is_month_complete = 1
       AND NOT EXISTS (SELECT 1 FROM stg.SalesOrderHeader AS h
                        WHERE YEAR(h.OrderDate) = d.[year] AND MONTH(h.OrderDate) = d.[month]);

    IF NOT (@bad_year = 0 AND @bad_month = 0)
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'nam co co sai=', @bad_year, N'; ngay thuoc thang "tron ven" nhung khong co don hang=', @bad_month);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DQ-03b', @res, @det);

-- ------------------------------------------------------------------
-- TC-DIM-05: sua tay 1 dong dimension -> chay proc -> dong do duoc sua lai,
--            khoa thay the khong doi, log ghi dung 1 dong da cap nhat
-- ------------------------------------------------------------------
DECLARE @pid INT, @k1 INT, @k2 INT, @orig NVARCHAR(50), @after NVARCHAR(50), @loaded_prod INT;
SET @res = 'FAIL'; SET @det = N'khong chay duoc';
BEGIN TRY
    SELECT TOP (1) @pid = product_id, @k1 = product_key, @orig = name
      FROM dwh.dim_product WHERE product_key > 0 ORDER BY product_key;

    UPDATE dwh.dim_product SET name = N'TAMPERED' WHERE product_id = @pid;

    EXEC dwh.usp_load_dims;

    SELECT @after = name, @k2 = product_key FROM dwh.dim_product WHERE product_id = @pid;
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @loaded_prod = rows_loaded FROM ops.etl_log WHERE run_id = @run AND step = N'dwh.dim_product';

    IF @after = @orig AND @k1 = @k2 AND @loaded_prod = 1
    BEGIN
        SET @res = 'PASS'; SET @det = NULL;
    END
    ELSE
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'ten sau=', @after, N' (goc=', @orig, N'); key truoc/sau=', @k1, N'/', @k2, N'; rows_loaded dim_product=', @loaded_prod);
    END;
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DIM-05', @res, @det);

-- ------------------------------------------------------------------
-- TC-DIM-04: loi gia lap giua chung -> ROLLBACK + log dung
-- Kiem chung ROLLBACK: pha ten 1 san pham (dim_product nap TRUOC diem loi).
-- Neu transaction da commit, proc se sua lai ten. Con 'TAMPERED' = da rollback.
-- ------------------------------------------------------------------
DECLARE @caught BIT, @err_no INT, @name_after NVARCHAR(50);
DECLARE @n_failed INT, @n_success INT, @n_rolled INT;
SET @res = 'FAIL'; SET @det = N'khong chay duoc';
SET @caught = 0;
BEGIN TRY
    EXEC dwh.usp_load_dims;                                          -- dua dimension ve trang thai sach
    SELECT TOP (1) @pid = product_id FROM dwh.dim_product WHERE product_key > 0 ORDER BY product_key;
    UPDATE dwh.dim_product SET name = N'TAMPERED' WHERE product_id = @pid;

    BEGIN TRY
        EXEC dwh.usp_load_dims @simulate_fail_after = N'dim_customer';
    END TRY
    BEGIN CATCH
        SET @caught = 1; SET @err_no = ERROR_NUMBER();
    END CATCH;

    SELECT @name_after = name FROM dwh.dim_product WHERE product_id = @pid;
    SELECT TOP (1) @run = run_id FROM ops.etl_log ORDER BY log_id DESC;
    SELECT @n_failed  = SUM(CASE WHEN status = 'FAILED'      THEN 1 ELSE 0 END),
           @n_success = SUM(CASE WHEN status = 'SUCCESS'     THEN 1 ELSE 0 END),
           @n_rolled  = SUM(CASE WHEN status = 'ROLLED_BACK' THEN 1 ELSE 0 END)
      FROM ops.etl_log WHERE run_id = @run;

    IF @caught = 1 AND @err_no = 50040 AND @name_after = N'TAMPERED'
       AND @n_failed = 1 AND @n_success = 0 AND @n_rolled >= 1
    BEGIN
        SET @res = 'PASS'; SET @det = NULL;
    END
    ELSE
    BEGIN
        SET @res = 'FAIL';
        SET @det = CONCAT(N'caught=', @caught, N', err=', @err_no, N', ten sau=', @name_after,
                          N', FAILED/SUCCESS/ROLLED_BACK=', @n_failed, N'/', @n_success, N'/', @n_rolled);
    END;

    EXEC dwh.usp_load_dims;                                          -- don dep: sua lai ten that
END TRY
BEGIN CATCH
    SET @res = 'FAIL'; SET @det = LEFT(ERROR_MESSAGE(), 1000);
END CATCH;
INSERT INTO #r VALUES ('TC-DIM-04', @res, @det);

-- ------------------------------------------------------------------
-- Ket qua
-- ------------------------------------------------------------------
SELECT test_id, result, detail FROM #r ORDER BY test_id;
SELECT SUM(CASE WHEN result = 'PASS' THEN 1 ELSE 0 END) AS passed,
       SUM(CASE WHEN result = 'FAIL' THEN 1 ELSE 0 END) AS failed
  FROM #r;
