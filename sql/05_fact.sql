/* =====================================================================
   05_fact.sql  -  3 bang su kien (fact), view quota-vs-actual, proc nap dwh.usp_load_facts
   Yeu cau: da chay 01..04; stg da nap (stg.usp_load_all); dimension da nap (dwh.usp_load_dims).
   Chay lai nhieu lan an toan (idempotent: TRUNCATE + nap lai trong 1 transaction).

   Quy uoc nghiep vu (ghi vao README):
     revenue      = LineTotal cua dong don ban (da tru chiet khau). KHONG gom thue (TaxAmt), phi van chuyen (Freight).
     discount_amt = OrderQty * UnitPrice - revenue           (revenue + discount_amt = doanh thu gop truoc chiet khau)
     cogs         = OrderQty * gia von don vi tai NGAY DAT HANG
                    - uu tien Production.ProductCostHistory (StartDate <= ngay dat <= EndDate; EndDate NULL = dang hieu luc;
                      neu nhieu dong cung khop thi lay dong co StartDate moi nhat) -> cogs_source = 'HISTORY'
                    - khong co dong lich su phu hop -> Product.StandardCost -> cogs_source = 'FALLBACK'
     gross_profit = revenue - cogs
     Purchasing   = PurchaseOrderDetail.LineTotal
     Quota        = Sales.SalesPersonQuotaHistory, quy ve NGAY DAU QUY DUONG LICH chua QuotaDate
     Do chinh xac: revenue/discount_amt/cogs/gross_profit la DECIMAL(19,6) (LineTotal nguon co 6 chu so thap phan;
                   neu cat con 4 so thi tong khong khop nguon). line_total, quota_amount: DECIMAL(19,4).

   Quy tac tu choi dong (ghi vao ops.reject, ETL van chay tiep, rows_rejected trong ops.etl_log):
     ORPHAN_HEADER, NON_POSITIVE_QTY, DATE_NOT_FOUND, DIM_NOT_FOUND: <dimension>,
     COST_NOT_FOUND, AMOUNT_OUT_OF_RANGE, DUPLICATE_QUOTA_PERIOD
     Khoa tu nhien NULL (SalesPersonID, TerritoryID) -> map ve key -1. Khoa tu nhien KHAC NULL ma khong co
     trong dimension -> TU CHOI (khong giau loi bang cach gan Unknown).
   ===================================================================== */
USE FinanceDW;
GO

-- ------------------------------ Bang fact ------------------------------
IF OBJECT_ID(N'dwh.fact_sales', N'U') IS NULL
CREATE TABLE dwh.fact_sales (
    sales_order_id        INT NOT NULL,
    sales_order_detail_id INT NOT NULL,
    date_key        INT NOT NULL CONSTRAINT FK_fact_sales_date        REFERENCES dwh.dim_date (date_key),
    product_key     INT NOT NULL CONSTRAINT FK_fact_sales_product     REFERENCES dwh.dim_product (product_key),
    customer_key    INT NOT NULL CONSTRAINT FK_fact_sales_customer    REFERENCES dwh.dim_customer (customer_key),
    territory_key   INT NOT NULL CONSTRAINT FK_fact_sales_territory   REFERENCES dwh.dim_territory (territory_key),
    salesperson_key INT NOT NULL CONSTRAINT FK_fact_sales_salesperson REFERENCES dwh.dim_salesperson (salesperson_key),
    order_qty       INT NOT NULL CONSTRAINT CK_fact_sales_qty CHECK (order_qty > 0),
    revenue         DECIMAL(19,6) NOT NULL,
    discount_amt    DECIMAL(19,6) NOT NULL,
    cogs            DECIMAL(19,6) NOT NULL,
    gross_profit    DECIMAL(19,6) NOT NULL,
    cogs_source     VARCHAR(8)    NOT NULL CONSTRAINT CK_fact_sales_cogs_source CHECK (cogs_source IN ('HISTORY', 'FALLBACK')),
    CONSTRAINT PK_fact_sales PRIMARY KEY (sales_order_id, sales_order_detail_id)
);
GO

IF OBJECT_ID(N'dwh.fact_purchasing', N'U') IS NULL
CREATE TABLE dwh.fact_purchasing (
    purchase_order_id        INT NOT NULL,
    purchase_order_detail_id INT NOT NULL,
    date_key    INT NOT NULL CONSTRAINT FK_fact_purchasing_date    REFERENCES dwh.dim_date (date_key),
    product_key INT NOT NULL CONSTRAINT FK_fact_purchasing_product REFERENCES dwh.dim_product (product_key),
    vendor_key  INT NOT NULL CONSTRAINT FK_fact_purchasing_vendor  REFERENCES dwh.dim_vendor (vendor_key),
    order_qty   INT NOT NULL CONSTRAINT CK_fact_purchasing_qty CHECK (order_qty > 0),
    line_total  DECIMAL(19,4) NOT NULL,
    CONSTRAINT PK_fact_purchasing PRIMARY KEY (purchase_order_id, purchase_order_detail_id)
);
GO

IF OBJECT_ID(N'dwh.fact_quota', N'U') IS NULL
CREATE TABLE dwh.fact_quota (
    salesperson_key INT NOT NULL CONSTRAINT FK_fact_quota_salesperson REFERENCES dwh.dim_salesperson (salesperson_key),
    date_key        INT NOT NULL CONSTRAINT FK_fact_quota_date        REFERENCES dwh.dim_date (date_key),   -- ngay dau quy
    quota_amount    DECIMAL(19,4) NOT NULL,
    CONSTRAINT PK_fact_quota PRIMARY KEY (salesperson_key, date_key)
);
GO

-- ------- View quota vs actual: cung grain quy x nhan vien, co co ro rang (TC-DQ-04) -------
-- has_quota / has_actual cho biet quy nao chi co ke hoach hoac chi co thuc te.
-- Chi tinh nhan vien ban hang that (salesperson_key <> -1), bo don online.
CREATE OR ALTER VIEW dwh.vw_quota_vs_actual
AS
WITH actual AS (
    SELECT f.salesperson_key,
           dd.[year] * 10000 + (((dd.[month] - 1) / 3) * 3 + 1) * 100 + 1 AS quarter_start_date_key,
           SUM(f.revenue) AS actual_revenue
      FROM dwh.fact_sales AS f
      JOIN dwh.dim_date   AS dd ON dd.date_key = f.date_key
     WHERE f.salesperson_key <> -1
     GROUP BY f.salesperson_key,
              dd.[year] * 10000 + (((dd.[month] - 1) / 3) * 3 + 1) * 100 + 1
)
SELECT COALESCE(q.salesperson_key, a.salesperson_key)       AS salesperson_key,
       COALESCE(q.date_key, a.quarter_start_date_key)       AS quarter_start_date_key,
       q.quota_amount                                       AS quota_amount,
       a.actual_revenue                                     AS actual_revenue,
       CAST(CASE WHEN q.salesperson_key IS NULL THEN 0 ELSE 1 END AS BIT) AS has_quota,
       CAST(CASE WHEN a.salesperson_key IS NULL THEN 0 ELSE 1 END AS BIT) AS has_actual
  FROM dwh.fact_quota AS q
  FULL OUTER JOIN actual AS a
    ON a.salesperson_key = q.salesperson_key
   AND a.quarter_start_date_key = q.date_key;
GO

-- --------------- Proc tien ich: anh chup cac fact (dung cho test) ---------------
CREATE OR ALTER PROCEDURE ops.usp_fact_snapshot
    @snap NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @snap = CONCAT(
        N'sales:',      (SELECT COUNT(*) FROM dwh.fact_sales),      N'/', (SELECT SUM(revenue) FROM dwh.fact_sales),
                        N'/', (SELECT SUM(cogs) FROM dwh.fact_sales), N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.fact_sales), N'; ',
        N'purchasing:', (SELECT COUNT(*) FROM dwh.fact_purchasing), N'/', (SELECT SUM(line_total) FROM dwh.fact_purchasing),
                        N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.fact_purchasing), N'; ',
        N'quota:',      (SELECT COUNT(*) FROM dwh.fact_quota),      N'/', (SELECT SUM(quota_amount) FROM dwh.fact_quota),
                        N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.fact_quota));
END;
GO

-- ------------------------- Proc nap toan bo fact -------------------------
CREATE OR ALTER PROCEDURE dwh.usp_load_facts
    @simulate_fail_after SYSNAME = NULL   -- CHI DUNG CHO TEST: 'fact_sales','fact_purchasing','fact_quota'
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @run_id UNIQUEIDENTIFIER = NEWID();

    -- Bien bang KHONG bi ROLLBACK -> giu duoc thong tin log khi transaction that bai
    DECLARE @steps TABLE (
        seq           INT IDENTITY(1,1) PRIMARY KEY,
        step          NVARCHAR(128) NOT NULL,
        start_time    DATETIME2(3)  NOT NULL,
        end_time      DATETIME2(3)  NOT NULL,
        rows_read     INT           NOT NULL,
        rows_loaded   INT           NOT NULL,
        rows_rejected INT           NOT NULL,
        status        VARCHAR(12)   NOT NULL,
        error_number  INT           NULL,
        error_message NVARCHAR(4000) NULL
    );

    DECLARE @current_step NVARCHAR(128) = N'precheck';
    DECLARE @step_start   DATETIME2(3)  = SYSUTCDATETIME();
    DECLARE @failed       BIT           = 0;
    DECLARE @err_no       INT;
    DECLARE @err_msg      NVARCHAR(4000);
    DECLARE @final_msg    NVARCHAR(2000);
    DECLARE @m            NVARCHAR(2000);
    DECLARE @rows_read    INT;
    DECLARE @ins          INT;
    DECLARE @rej          INT;
    DECLARE @fallback     INT;

    BEGIN TRY
        -- 0. Kiem tra dieu kien dau vao (ngoai transaction)
        IF NOT (EXISTS (SELECT 1 FROM stg.SalesOrderDetail)
            AND EXISTS (SELECT 1 FROM stg.SalesOrderHeader)
            AND EXISTS (SELECT 1 FROM stg.PurchaseOrderDetail)
            AND EXISTS (SELECT 1 FROM stg.PurchaseOrderHeader)
            AND EXISTS (SELECT 1 FROM stg.SalesPersonQuotaHistory)
            AND EXISTS (SELECT 1 FROM dwh.dim_date)
            AND EXISTS (SELECT 1 FROM dwh.dim_product     WHERE product_key     > 0)
            AND EXISTS (SELECT 1 FROM dwh.dim_customer    WHERE customer_key    > 0)
            AND EXISTS (SELECT 1 FROM dwh.dim_territory   WHERE territory_key   > 0)
            AND EXISTS (SELECT 1 FROM dwh.dim_salesperson WHERE salesperson_key > 0)
            AND EXISTS (SELECT 1 FROM dwh.dim_vendor      WHERE vendor_key      > 0))
        BEGIN
            SET @m = N'stg hoac dimension con rong. Chay EXEC stg.usp_load_all; EXEC dwh.usp_load_dims; truoc.';
            THROW 50050, @m, 1;
        END;

        BEGIN TRANSACTION;

        -- 1. fact_sales ----------------------------------------------------
        SET @current_step = N'dwh.fact_sales';
        SET @step_start   = SYSUTCDATETIME();

        SELECT d.SalesOrderID        AS sales_order_id,
               d.SalesOrderDetailID  AS sales_order_detail_id,
               d.OrderQty            AS order_qty,
               d.UnitPrice           AS unit_price,
               d.UnitPriceDiscount   AS unit_price_discount,
               d.LineTotal           AS line_total_src,
               dd.date_key           AS date_key,
               dp.product_key        AS product_key,
               dc.customer_key       AS customer_key,
               CASE WHEN h.TerritoryID   IS NULL THEN -1 ELSE dt.territory_key   END AS territory_key,
               CASE WHEN h.SalesPersonID IS NULL THEN -1 ELSE ds.salesperson_key END AS salesperson_key,
               calc.revenue          AS revenue,
               calc.gross_amt        AS gross_amt,
               calc.cogs             AS cogs,
               CAST(CASE WHEN hist.unit_cost IS NOT NULL THEN 'HISTORY' ELSE 'FALLBACK' END AS VARCHAR(8)) AS cogs_source,
               CAST(CASE
                        WHEN h.SalesOrderID IS NULL                                   THEN N'ORPHAN_HEADER'
                        WHEN d.OrderQty <= 0                                          THEN N'NON_POSITIVE_QTY'
                        WHEN dd.date_key IS NULL                                      THEN N'DATE_NOT_FOUND'
                        WHEN dp.product_key IS NULL                                   THEN N'DIM_NOT_FOUND: product'
                        WHEN dc.customer_key IS NULL                                  THEN N'DIM_NOT_FOUND: customer'
                        WHEN h.TerritoryID IS NOT NULL AND dt.territory_key IS NULL   THEN N'DIM_NOT_FOUND: territory'
                        WHEN h.SalesPersonID IS NOT NULL AND ds.salesperson_key IS NULL THEN N'DIM_NOT_FOUND: salesperson'
                        WHEN hist.unit_cost IS NULL AND pr.StandardCost IS NULL       THEN N'COST_NOT_FOUND'
                        WHEN calc.revenue IS NULL OR calc.gross_amt IS NULL OR calc.cogs IS NULL THEN N'AMOUNT_OUT_OF_RANGE'
                        ELSE NULL
                    END AS NVARCHAR(100)) AS reject_reason
          INTO #fs
          FROM stg.SalesOrderDetail AS d
          LEFT JOIN stg.SalesOrderHeader AS h  ON h.SalesOrderID = d.SalesOrderID
          LEFT JOIN dwh.dim_date         AS dd ON dd.full_date = CAST(h.OrderDate AS DATE)
          LEFT JOIN dwh.dim_product      AS dp ON dp.product_id = d.ProductID
          LEFT JOIN dwh.dim_customer     AS dc ON dc.customer_id = h.CustomerID
          LEFT JOIN dwh.dim_territory    AS dt ON dt.territory_id = h.TerritoryID
          LEFT JOIN dwh.dim_salesperson  AS ds ON ds.business_entity_id = h.SalesPersonID
          LEFT JOIN stg.Product          AS pr ON pr.ProductID = d.ProductID
          OUTER APPLY (
              SELECT TOP (1) ch.StandardCost AS unit_cost
                FROM stg.ProductCostHistory AS ch
               WHERE ch.ProductID = d.ProductID
                 AND CAST(h.OrderDate AS DATE) >= CAST(ch.StartDate AS DATE)
                 AND (ch.EndDate IS NULL OR CAST(h.OrderDate AS DATE) <= CAST(ch.EndDate AS DATE))
               ORDER BY ch.StartDate DESC
          ) AS hist
          CROSS APPLY (
              SELECT TRY_CAST(COALESCE(d.LineTotal, d.UnitPrice * (1 - d.UnitPriceDiscount) * d.OrderQty) AS DECIMAL(19,6)) AS revenue,
                     TRY_CAST(d.OrderQty * d.UnitPrice AS DECIMAL(19,6))                                                    AS gross_amt,
                     TRY_CAST(d.OrderQty * COALESCE(hist.unit_cost, pr.StandardCost) AS DECIMAL(19,6))                      AS cogs
          ) AS calc;
        SET @rows_read = @@ROWCOUNT;

        TRUNCATE TABLE dwh.fact_sales;

        INSERT INTO dwh.fact_sales (sales_order_id, sales_order_detail_id, date_key, product_key, customer_key, territory_key,
                                    salesperson_key, order_qty, revenue, discount_amt, cogs, gross_profit, cogs_source)
        SELECT sales_order_id, sales_order_detail_id, date_key, product_key, customer_key, territory_key,
               salesperson_key, order_qty, revenue, gross_amt - revenue, cogs, revenue - cogs, cogs_source
          FROM #fs
         WHERE reject_reason IS NULL;
        SET @ins = @@ROWCOUNT;

        INSERT INTO ops.reject (run_id, step, source_key, reason, raw_row)
        SELECT @run_id, @current_step,
               CONCAT(sales_order_id, N'/', sales_order_detail_id),
               reject_reason,
               CONCAT(N'OrderQty=', order_qty, N'; UnitPrice=', unit_price, N'; UnitPriceDiscount=', unit_price_discount, N'; LineTotal=', line_total_src)
          FROM #fs
         WHERE reject_reason IS NOT NULL;
        SET @rej = @@ROWCOUNT;

        IF @ins + @rej <> @rows_read
        BEGIN
            SET @m = N'Lech so dong tai ' + @current_step + N': doc ' + CAST(@rows_read AS NVARCHAR(20))
                   + N', nap ' + CAST(@ins AS NVARCHAR(20)) + N', tu choi ' + CAST(@rej AS NVARCHAR(20)) + N'.';
            THROW 50051, @m, 1;
        END;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins, @rej, 'SUCCESS', NULL, NULL);

        -- Dong thong tin: so dong dung gia von du phong (FALLBACK). rows_read = so dong fact, rows_loaded = so dong FALLBACK
        SELECT @fallback = COUNT(*) FROM dwh.fact_sales WHERE cogs_source = 'FALLBACK';
        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (N'dwh.fact_sales[cogs_fallback]', @step_start, SYSUTCDATETIME(), @ins, @fallback, 0, 'SUCCESS', NULL, NULL);

        IF @simulate_fail_after = N'fact_sales'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 2. fact_purchasing -----------------------------------------------
        SET @current_step = N'dwh.fact_purchasing';
        SET @step_start   = SYSUTCDATETIME();

        SELECT d.PurchaseOrderID        AS purchase_order_id,
               d.PurchaseOrderDetailID  AS purchase_order_detail_id,
               d.OrderQty               AS order_qty,
               d.UnitPrice              AS unit_price,
               d.LineTotal              AS line_total_src,
               dd.date_key              AS date_key,
               dp.product_key           AS product_key,
               dv.vendor_key            AS vendor_key,
               calc.line_total          AS line_total,
               CAST(CASE
                        WHEN h.PurchaseOrderID IS NULL THEN N'ORPHAN_HEADER'
                        WHEN d.OrderQty <= 0           THEN N'NON_POSITIVE_QTY'
                        WHEN dd.date_key IS NULL       THEN N'DATE_NOT_FOUND'
                        WHEN dp.product_key IS NULL    THEN N'DIM_NOT_FOUND: product'
                        WHEN dv.vendor_key IS NULL     THEN N'DIM_NOT_FOUND: vendor'
                        WHEN calc.line_total IS NULL   THEN N'AMOUNT_OUT_OF_RANGE'
                        ELSE NULL
                    END AS NVARCHAR(100)) AS reject_reason
          INTO #fp
          FROM stg.PurchaseOrderDetail AS d
          LEFT JOIN stg.PurchaseOrderHeader AS h  ON h.PurchaseOrderID = d.PurchaseOrderID
          LEFT JOIN dwh.dim_date            AS dd ON dd.full_date = CAST(h.OrderDate AS DATE)
          LEFT JOIN dwh.dim_product         AS dp ON dp.product_id = d.ProductID
          LEFT JOIN dwh.dim_vendor          AS dv ON dv.vendor_id = h.VendorID
          CROSS APPLY (
              SELECT TRY_CAST(COALESCE(d.LineTotal, d.OrderQty * d.UnitPrice) AS DECIMAL(19,4)) AS line_total
          ) AS calc;
        SET @rows_read = @@ROWCOUNT;

        TRUNCATE TABLE dwh.fact_purchasing;

        INSERT INTO dwh.fact_purchasing (purchase_order_id, purchase_order_detail_id, date_key, product_key, vendor_key, order_qty, line_total)
        SELECT purchase_order_id, purchase_order_detail_id, date_key, product_key, vendor_key, order_qty, line_total
          FROM #fp
         WHERE reject_reason IS NULL;
        SET @ins = @@ROWCOUNT;

        INSERT INTO ops.reject (run_id, step, source_key, reason, raw_row)
        SELECT @run_id, @current_step,
               CONCAT(purchase_order_id, N'/', purchase_order_detail_id),
               reject_reason,
               CONCAT(N'OrderQty=', order_qty, N'; UnitPrice=', unit_price, N'; LineTotal=', line_total_src)
          FROM #fp
         WHERE reject_reason IS NOT NULL;
        SET @rej = @@ROWCOUNT;

        IF @ins + @rej <> @rows_read
        BEGIN
            SET @m = N'Lech so dong tai ' + @current_step + N': doc ' + CAST(@rows_read AS NVARCHAR(20))
                   + N', nap ' + CAST(@ins AS NVARCHAR(20)) + N', tu choi ' + CAST(@rej AS NVARCHAR(20)) + N'.';
            THROW 50051, @m, 1;
        END;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins, @rej, 'SUCCESS', NULL, NULL);

        IF @simulate_fail_after = N'fact_purchasing'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 3. fact_quota ----------------------------------------------------
        SET @current_step = N'dwh.fact_quota';
        SET @step_start   = SYSUTCDATETIME();

        SELECT q.BusinessEntityID  AS business_entity_id,
               q.QuotaDate         AS quota_date,
               q.SalesQuota        AS quota_amount,
               ds.salesperson_key  AS salesperson_key,
               dd.date_key         AS date_key,
               CAST(CASE
                        WHEN ds.salesperson_key IS NULL THEN N'DIM_NOT_FOUND: salesperson'
                        WHEN dd.date_key IS NULL        THEN N'DATE_NOT_FOUND'
                        WHEN EXISTS (SELECT 1
                                       FROM stg.SalesPersonQuotaHistory AS q2
                                      WHERE q2.BusinessEntityID = q.BusinessEntityID
                                        AND q2.QuotaDate > q.QuotaDate
                                        AND DATEFROMPARTS(YEAR(q2.QuotaDate), ((MONTH(q2.QuotaDate) - 1) / 3) * 3 + 1, 1) = qa.quarter_start)
                                                        THEN N'DUPLICATE_QUOTA_PERIOD'
                        ELSE NULL
                    END AS NVARCHAR(100)) AS reject_reason
          INTO #fq
          FROM stg.SalesPersonQuotaHistory AS q
          CROSS APPLY (SELECT DATEFROMPARTS(YEAR(q.QuotaDate), ((MONTH(q.QuotaDate) - 1) / 3) * 3 + 1, 1) AS quarter_start) AS qa
          LEFT JOIN dwh.dim_salesperson AS ds ON ds.business_entity_id = q.BusinessEntityID
          LEFT JOIN dwh.dim_date        AS dd ON dd.full_date = qa.quarter_start;
        SET @rows_read = @@ROWCOUNT;

        TRUNCATE TABLE dwh.fact_quota;

        INSERT INTO dwh.fact_quota (salesperson_key, date_key, quota_amount)
        SELECT salesperson_key, date_key, quota_amount
          FROM #fq
         WHERE reject_reason IS NULL;
        SET @ins = @@ROWCOUNT;

        INSERT INTO ops.reject (run_id, step, source_key, reason, raw_row)
        SELECT @run_id, @current_step,
               CONCAT(business_entity_id, N'/', CONVERT(CHAR(10), quota_date, 23)),
               reject_reason,
               CONCAT(N'SalesQuota=', quota_amount)
          FROM #fq
         WHERE reject_reason IS NOT NULL;
        SET @rej = @@ROWCOUNT;

        IF @ins + @rej <> @rows_read
        BEGIN
            SET @m = N'Lech so dong tai ' + @current_step + N': doc ' + CAST(@rows_read AS NVARCHAR(20))
                   + N', nap ' + CAST(@ins AS NVARCHAR(20)) + N', tu choi ' + CAST(@rej AS NVARCHAR(20)) + N'.';
            THROW 50051, @m, 1;
        END;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins, @rej, 'SUCCESS', NULL, NULL);

        IF @simulate_fail_after = N'fact_quota'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @failed  = 1;
        SET @err_no  = ERROR_NUMBER();
        SET @err_msg = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        -- Cac buoc da xong trong transaction nay (ke ca ops.reject cua chung) da bi hoan tac
        UPDATE @steps SET status = 'ROLLED_BACK' WHERE status = 'SUCCESS';

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), 0, 0, 0, 'FAILED', @err_no, @err_msg);
    END CATCH;

    -- Ghi log (ngoai transaction -> luon duoc luu)
    INSERT INTO ops.etl_log (run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
    SELECT @run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message
      FROM @steps
     ORDER BY seq;

    IF @failed = 1
    BEGIN
        SET @final_msg = LEFT(N'dwh.usp_load_facts that bai tai buoc ' + @current_step
                            + N' (loi ' + CAST(@err_no AS NVARCHAR(20)) + N'): ' + @err_msg, 2000);
        THROW 50060, @final_msg, 1;
    END;
END;
GO
