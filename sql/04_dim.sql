/* =====================================================================
   04_dim.sql  -  6 bang chieu (dimension) trong schema dwh + proc nap dwh.usp_load_dims
   Yeu cau: da chay 01, 02, 03 va da nap stg (EXEC stg.usp_load_all).
   Chay lai nhieu lan an toan (idempotent).

   Thiet ke phong thu:
     - Nap kieu UPSERT theo khoa tu nhien (UPDATE neu khac + INSERT neu moi, KHONG xoa)
       -> khoa thay the (surrogate key) on dinh, khong lam gay khoa ngoai o bang fact sau nay.
     - Tat ca dimension nap trong MOT transaction; loi -> ROLLBACK het; log vao ops.etl_log
       sau khi transaction ket thuc (giong stg.usp_load_all).
     - Moi dimension (tru dim_date) co dong Unknown voi key = -1.
       dim_date KHONG co dong Unknown: ngay dat hang o nguon luon NOT NULL, va mot dong
       1900-01-01 se tao khoang trong lam hong Date table / time intelligence trong Power BI.
     - dim_date sinh LIEN TUC tu ngay 1/1 cua nam nho nhat den 31/12 cua nam lon nhat trong du lieu.
       Hai co do do phu du lieu ban hang (stg.SalesOrderHeader.OrderDate):
         is_month_complete = thang nam tron ven trong khoang du lieu ban hang
         is_year_complete  = nam nam tron ven trong khoang du lieu ban hang
     - Khong dung DATENAME/DATEPART(weekday): phu thuoc ngon ngu / DATEFIRST cua phien lam viec.
   ===================================================================== */
USE FinanceDW;
GO

-- ------------------------------ Bang dimension ------------------------------
IF OBJECT_ID(N'dwh.dim_date', N'U') IS NULL
CREATE TABLE dwh.dim_date (
    date_key          INT      NOT NULL CONSTRAINT PK_dim_date PRIMARY KEY,   -- yyyymmdd
    full_date         DATE     NOT NULL CONSTRAINT UQ_dim_date_full_date UNIQUE,
    [year]            SMALLINT NOT NULL,
    [quarter]         TINYINT  NOT NULL,
    [month]           TINYINT  NOT NULL,
    year_month        CHAR(7)  NOT NULL,                                       -- 'yyyy-MM'
    is_month_complete BIT      NOT NULL,
    is_year_complete  BIT      NOT NULL,
    CONSTRAINT CK_dim_date_key CHECK (date_key = YEAR(full_date) * 10000 + MONTH(full_date) * 100 + DAY(full_date))
);
GO

IF OBJECT_ID(N'dwh.dim_product', N'U') IS NULL
CREATE TABLE dwh.dim_product (
    product_key INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_product PRIMARY KEY,
    product_id  INT           NOT NULL CONSTRAINT UQ_dim_product_nk UNIQUE,
    name        NVARCHAR(50)  NOT NULL,
    subcategory NVARCHAR(50)  NOT NULL,
    category    NVARCHAR(50)  NOT NULL,
    list_price  DECIMAL(19,4) NOT NULL
);
GO

IF OBJECT_ID(N'dwh.dim_customer', N'U') IS NULL
CREATE TABLE dwh.dim_customer (
    customer_key  INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_customer PRIMARY KEY,
    customer_id   INT          NOT NULL CONSTRAINT UQ_dim_customer_nk UNIQUE,
    customer_type NVARCHAR(20) NOT NULL
);
GO

IF OBJECT_ID(N'dwh.dim_territory', N'U') IS NULL
CREATE TABLE dwh.dim_territory (
    territory_key       INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_territory PRIMARY KEY,
    territory_id        INT          NOT NULL CONSTRAINT UQ_dim_territory_nk UNIQUE,
    name                NVARCHAR(50) NOT NULL,
    country_region_code NVARCHAR(3)  NOT NULL,
    region_group        NVARCHAR(50) NOT NULL
);
GO

IF OBJECT_ID(N'dwh.dim_salesperson', N'U') IS NULL
CREATE TABLE dwh.dim_salesperson (
    salesperson_key    INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_salesperson PRIMARY KEY,
    business_entity_id INT           NOT NULL CONSTRAINT UQ_dim_salesperson_nk UNIQUE,
    full_name          NVARCHAR(120) NOT NULL
);
GO

IF OBJECT_ID(N'dwh.dim_vendor', N'U') IS NULL
CREATE TABLE dwh.dim_vendor (
    vendor_key INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_dim_vendor PRIMARY KEY,
    vendor_id  INT          NOT NULL CONSTRAINT UQ_dim_vendor_nk UNIQUE,
    name       NVARCHAR(50) NOT NULL
);
GO

-- ------------------- Dong Unknown (key = -1), idempotent -------------------
-- IDENTITY_INSERT cho phep chen key am; khoa that van bat dau tu 1.
IF NOT EXISTS (SELECT 1 FROM dwh.dim_product WHERE product_key = -1)
BEGIN
    SET IDENTITY_INSERT dwh.dim_product ON;
    INSERT INTO dwh.dim_product (product_key, product_id, name, subcategory, category, list_price)
    VALUES (-1, -1, N'Unknown', N'Unknown', N'Unknown', 0);
    SET IDENTITY_INSERT dwh.dim_product OFF;
END;

IF NOT EXISTS (SELECT 1 FROM dwh.dim_customer WHERE customer_key = -1)
BEGIN
    SET IDENTITY_INSERT dwh.dim_customer ON;
    INSERT INTO dwh.dim_customer (customer_key, customer_id, customer_type)
    VALUES (-1, -1, N'Unknown');
    SET IDENTITY_INSERT dwh.dim_customer OFF;
END;

IF NOT EXISTS (SELECT 1 FROM dwh.dim_territory WHERE territory_key = -1)
BEGIN
    SET IDENTITY_INSERT dwh.dim_territory ON;
    INSERT INTO dwh.dim_territory (territory_key, territory_id, name, country_region_code, region_group)
    VALUES (-1, -1, N'Unknown', N'--', N'Unknown');
    SET IDENTITY_INSERT dwh.dim_territory OFF;
END;

IF NOT EXISTS (SELECT 1 FROM dwh.dim_salesperson WHERE salesperson_key = -1)
BEGIN
    SET IDENTITY_INSERT dwh.dim_salesperson ON;
    INSERT INTO dwh.dim_salesperson (salesperson_key, business_entity_id, full_name)
    VALUES (-1, -1, N'(No salesperson)');   -- don online (SalesPersonID NULL) se tro vao day
    SET IDENTITY_INSERT dwh.dim_salesperson OFF;
END;

IF NOT EXISTS (SELECT 1 FROM dwh.dim_vendor WHERE vendor_key = -1)
BEGIN
    SET IDENTITY_INSERT dwh.dim_vendor ON;
    INSERT INTO dwh.dim_vendor (vendor_key, vendor_id, name)
    VALUES (-1, -1, N'Unknown');
    SET IDENTITY_INSERT dwh.dim_vendor OFF;
END;
GO

-- --------------- Proc tien ich: anh chup cac dimension (dung cho test) ---------------
CREATE OR ALTER PROCEDURE ops.usp_dim_snapshot
    @snap NVARCHAR(MAX) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET @snap = CONCAT(
        N'date:',        (SELECT COUNT(*) FROM dwh.dim_date),        N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_date),        N'; ',
        N'product:',     (SELECT COUNT(*) FROM dwh.dim_product),     N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_product),     N'; ',
        N'customer:',    (SELECT COUNT(*) FROM dwh.dim_customer),    N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_customer),    N'; ',
        N'territory:',   (SELECT COUNT(*) FROM dwh.dim_territory),   N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_territory),   N'; ',
        N'salesperson:', (SELECT COUNT(*) FROM dwh.dim_salesperson), N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_salesperson), N'; ',
        N'vendor:',      (SELECT COUNT(*) FROM dwh.dim_vendor),      N'/', (SELECT CHECKSUM_AGG(CHECKSUM(*)) FROM dwh.dim_vendor));
END;
GO

-- ------------------------- Proc nap toan bo dimension -------------------------
CREATE OR ALTER PROCEDURE dwh.usp_load_dims
    @simulate_fail_after SYSNAME = NULL   -- CHI DUNG CHO TEST: 'dim_date','dim_product','dim_customer','dim_territory','dim_salesperson','dim_vendor'
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
        rows_loaded   INT           NOT NULL,   -- = so dong INSERT moi + so dong UPDATE co thay doi
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
    DECLARE @upd          INT;
    DECLARE @d_min        DATE;
    DECLARE @d_max        DATE;
    DECLARE @cov_min      DATE;
    DECLARE @cov_max      DATE;
    DECLARE @d_start      DATE;
    DECLARE @d_end        DATE;

    BEGIN TRY
        -- 0. Kiem tra stg da co du lieu (ngoai transaction)
        IF NOT (EXISTS (SELECT 1 FROM stg.SalesOrderHeader)
            AND EXISTS (SELECT 1 FROM stg.Product)
            AND EXISTS (SELECT 1 FROM stg.Customer)
            AND EXISTS (SELECT 1 FROM stg.SalesTerritory)
            AND EXISTS (SELECT 1 FROM stg.SalesPerson)
            AND EXISTS (SELECT 1 FROM stg.Vendor))
        BEGIN
            SET @m = N'Bang stg con rong. Chay EXEC stg.usp_load_all truoc.';
            THROW 50030, @m, 1;
        END;

        -- Khoang ngay can sinh: bao phu moi fact; lam tron ra nam day du
        SELECT @d_min = MIN(x.d), @d_max = MAX(x.d)
          FROM (SELECT CAST(OrderDate AS DATE) AS d FROM stg.SalesOrderHeader
                UNION ALL SELECT CAST(OrderDate AS DATE) FROM stg.PurchaseOrderHeader
                UNION ALL SELECT CAST(QuotaDate AS DATE) FROM stg.SalesPersonQuotaHistory) AS x;
        -- Khoang phu du lieu BAN HANG dung de tinh co "ky tron ven"
        SELECT @cov_min = MIN(CAST(OrderDate AS DATE)), @cov_max = MAX(CAST(OrderDate AS DATE))
          FROM stg.SalesOrderHeader;

        SET @d_start = DATEFROMPARTS(YEAR(@d_min), 1, 1);
        SET @d_end   = DATEFROMPARTS(YEAR(@d_max), 12, 31);

        BEGIN TRANSACTION;

        -- 1. dim_date ----------------------------------------------------------
        SET @current_step = N'dwh.dim_date';
        SET @step_start   = SYSUTCDATETIME();

        ;WITH n AS (
            SELECT TOP (DATEDIFF(DAY, @d_start, @d_end) + 1)
                   CAST(ROW_NUMBER() OVER (ORDER BY (SELECT NULL)) - 1 AS INT) AS i
              FROM sys.all_objects AS a CROSS JOIN sys.all_objects AS b
        )
        SELECT CAST(YEAR(x.d) * 10000 + MONTH(x.d) * 100 + DAY(x.d) AS INT)   AS date_key,
               x.d                                                            AS full_date,
               CAST(YEAR(x.d) AS SMALLINT)                                    AS [year],
               CAST((MONTH(x.d) - 1) / 3 + 1 AS TINYINT)                      AS [quarter],
               CAST(MONTH(x.d) AS TINYINT)                                    AS [month],
               CAST(LEFT(CONVERT(CHAR(10), x.d, 23), 7) AS CHAR(7))           AS year_month,
               CAST(CASE WHEN DATEFROMPARTS(YEAR(x.d), MONTH(x.d), 1) >= @cov_min
                          AND EOMONTH(x.d) <= @cov_max THEN 1 ELSE 0 END AS BIT) AS is_month_complete,
               CAST(CASE WHEN DATEFROMPARTS(YEAR(x.d), 1, 1)   >= @cov_min
                          AND DATEFROMPARTS(YEAR(x.d), 12, 31) <= @cov_max THEN 1 ELSE 0 END AS BIT) AS is_year_complete
          INTO #s_date
          FROM n CROSS APPLY (SELECT DATEADD(DAY, n.i, @d_start) AS d) AS x;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.is_month_complete = s.is_month_complete,
               d.is_year_complete  = s.is_year_complete
          FROM dwh.dim_date AS d
          JOIN #s_date AS s ON s.date_key = d.date_key
         WHERE d.is_month_complete <> s.is_month_complete
            OR d.is_year_complete  <> s.is_year_complete;
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_date (date_key, full_date, [year], [quarter], [month], year_month, is_month_complete, is_year_complete)
        SELECT s.date_key, s.full_date, s.[year], s.[quarter], s.[month], s.year_month, s.is_month_complete, s.is_year_complete
          FROM #s_date AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_date AS d WHERE d.date_key = s.date_key);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_date'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 2. dim_product -------------------------------------------------------
        SET @current_step = N'dwh.dim_product';
        SET @step_start   = SYSUTCDATETIME();

        SELECT p.ProductID                           AS product_id,
               p.Name                                AS name,
               COALESCE(sc.Name, N'Unassigned')      AS subcategory,
               COALESCE(c.Name,  N'Unassigned')      AS category,
               p.ListPrice                           AS list_price
          INTO #s_product
          FROM stg.Product AS p
          LEFT JOIN stg.ProductSubcategory AS sc ON sc.ProductSubcategoryID = p.ProductSubcategoryID
          LEFT JOIN stg.ProductCategory    AS c  ON c.ProductCategoryID     = sc.ProductCategoryID;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.name = s.name, d.subcategory = s.subcategory, d.category = s.category, d.list_price = s.list_price
          FROM dwh.dim_product AS d
          JOIN #s_product AS s ON s.product_id = d.product_id
         WHERE EXISTS (SELECT s.name, s.subcategory, s.category, s.list_price
                       EXCEPT
                       SELECT d.name, d.subcategory, d.category, d.list_price);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_product (product_id, name, subcategory, category, list_price)
        SELECT s.product_id, s.name, s.subcategory, s.category, s.list_price
          FROM #s_product AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_product AS d WHERE d.product_id = s.product_id);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_product'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 3. dim_customer ------------------------------------------------------
        SET @current_step = N'dwh.dim_customer';
        SET @step_start   = SYSUTCDATETIME();

        SELECT c.CustomerID AS customer_id,
               CAST(CASE WHEN c.StoreID  IS NOT NULL THEN N'Store'
                         WHEN c.PersonID IS NOT NULL THEN N'Individual'
                         ELSE N'Unknown' END AS NVARCHAR(20)) AS customer_type
          INTO #s_customer
          FROM stg.Customer AS c;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.customer_type = s.customer_type
          FROM dwh.dim_customer AS d
          JOIN #s_customer AS s ON s.customer_id = d.customer_id
         WHERE EXISTS (SELECT s.customer_type EXCEPT SELECT d.customer_type);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_customer (customer_id, customer_type)
        SELECT s.customer_id, s.customer_type
          FROM #s_customer AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_customer AS d WHERE d.customer_id = s.customer_id);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_customer'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 4. dim_territory -----------------------------------------------------
        SET @current_step = N'dwh.dim_territory';
        SET @step_start   = SYSUTCDATETIME();

        SELECT t.TerritoryID        AS territory_id,
               t.Name               AS name,
               t.CountryRegionCode  AS country_region_code,
               t.TerritoryGroup     AS region_group
          INTO #s_territory
          FROM stg.SalesTerritory AS t;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.name = s.name, d.country_region_code = s.country_region_code, d.region_group = s.region_group
          FROM dwh.dim_territory AS d
          JOIN #s_territory AS s ON s.territory_id = d.territory_id
         WHERE EXISTS (SELECT s.name, s.country_region_code, s.region_group
                       EXCEPT
                       SELECT d.name, d.country_region_code, d.region_group);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_territory (territory_id, name, country_region_code, region_group)
        SELECT s.territory_id, s.name, s.country_region_code, s.region_group
          FROM #s_territory AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_territory AS d WHERE d.territory_id = s.territory_id);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_territory'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 5. dim_salesperson ---------------------------------------------------
        SET @current_step = N'dwh.dim_salesperson';
        SET @step_start   = SYSUTCDATETIME();

        SELECT sp.BusinessEntityID AS business_entity_id,
               CAST(COALESCE(p.FirstName + N' ' + p.LastName,
                             N'(no name) #' + CAST(sp.BusinessEntityID AS NVARCHAR(20))) AS NVARCHAR(120)) AS full_name
          INTO #s_salesperson
          FROM stg.SalesPerson AS sp
          LEFT JOIN stg.Person AS p ON p.BusinessEntityID = sp.BusinessEntityID;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.full_name = s.full_name
          FROM dwh.dim_salesperson AS d
          JOIN #s_salesperson AS s ON s.business_entity_id = d.business_entity_id
         WHERE EXISTS (SELECT s.full_name EXCEPT SELECT d.full_name);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_salesperson (business_entity_id, full_name)
        SELECT s.business_entity_id, s.full_name
          FROM #s_salesperson AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_salesperson AS d WHERE d.business_entity_id = s.business_entity_id);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_salesperson'
        BEGIN
            SET @m = N'Simulated failure after ' + @current_step;
            THROW 50099, @m, 1;
        END;

        -- 6. dim_vendor --------------------------------------------------------
        SET @current_step = N'dwh.dim_vendor';
        SET @step_start   = SYSUTCDATETIME();

        SELECT v.BusinessEntityID AS vendor_id,
               v.Name             AS name
          INTO #s_vendor
          FROM stg.Vendor AS v;
        SET @rows_read = @@ROWCOUNT;

        UPDATE d
           SET d.name = s.name
          FROM dwh.dim_vendor AS d
          JOIN #s_vendor AS s ON s.vendor_id = d.vendor_id
         WHERE EXISTS (SELECT s.name EXCEPT SELECT d.name);
        SET @upd = @@ROWCOUNT;

        INSERT INTO dwh.dim_vendor (vendor_id, name)
        SELECT s.vendor_id, s.name
          FROM #s_vendor AS s
         WHERE NOT EXISTS (SELECT 1 FROM dwh.dim_vendor AS d WHERE d.vendor_id = s.vendor_id);
        SET @ins = @@ROWCOUNT;

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @ins + @upd, 0, 'SUCCESS', NULL, NULL);
        IF @simulate_fail_after = N'dim_vendor'
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

        -- Cac buoc da xong trong transaction nay da bi hoan tac
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
        SET @final_msg = LEFT(N'dwh.usp_load_dims that bai tai buoc ' + @current_step
                            + N' (loi ' + CAST(@err_no AS NVARCHAR(20)) + N'): ' + @err_msg, 2000);
        THROW 50040, @final_msg, 1;
    END;
END;
GO
