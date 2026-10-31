/* =====================================================================
   03_stg.sql  -  Bang staging (ban sao trung thuc cua nguon) + proc nap stg
   Yeu cau: da chay 01_restore.sql va 02_schemas_ops.sql.
   Phong thu:
     - Nap TAT CA bang stg trong MOT transaction (TRUNCATE + INSERT) -> loi la ROLLBACK het
     - Idempotent: chay lai bao nhieu lan cung cho cung ket qua (TC-ETL-01)
     - Log theo buoc vao ops.etl_log SAU khi transaction ket thuc (khong bi rollback cung)
       (TC-ETL-02, TC-ETL-07)
     - Doi chieu so dong nguon/dich tung bang, lech -> loi
   Tien te: DECIMAL(19,4) (tuong duong MONEY, khong dung FLOAT).
   ===================================================================== */
USE FinanceDW;
GO

-- ------------------------------ Bang stg ------------------------------
IF OBJECT_ID(N'stg.ProductCategory', N'U') IS NULL
CREATE TABLE stg.ProductCategory (
    ProductCategoryID INT          NOT NULL CONSTRAINT PK_stg_ProductCategory PRIMARY KEY,
    Name              NVARCHAR(50) NOT NULL,
    etl_run_id        UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.ProductSubcategory', N'U') IS NULL
CREATE TABLE stg.ProductSubcategory (
    ProductSubcategoryID INT          NOT NULL CONSTRAINT PK_stg_ProductSubcategory PRIMARY KEY,
    ProductCategoryID    INT          NOT NULL,
    Name                 NVARCHAR(50) NOT NULL,
    etl_run_id           UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.Product', N'U') IS NULL
CREATE TABLE stg.Product (
    ProductID            INT           NOT NULL CONSTRAINT PK_stg_Product PRIMARY KEY,
    Name                 NVARCHAR(50)  NOT NULL,
    ProductNumber        NVARCHAR(25)  NOT NULL,
    StandardCost         DECIMAL(19,4) NOT NULL,
    ListPrice            DECIMAL(19,4) NOT NULL,
    ProductSubcategoryID INT           NULL,
    SellStartDate        DATETIME      NOT NULL,
    SellEndDate          DATETIME      NULL,
    etl_run_id           UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.ProductCostHistory', N'U') IS NULL
CREATE TABLE stg.ProductCostHistory (
    ProductID    INT           NOT NULL,
    StartDate    DATETIME      NOT NULL,
    EndDate      DATETIME      NULL,
    StandardCost DECIMAL(19,4) NOT NULL,
    etl_run_id   UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_stg_ProductCostHistory PRIMARY KEY (ProductID, StartDate)
);
GO
IF OBJECT_ID(N'stg.SalesTerritory', N'U') IS NULL
CREATE TABLE stg.SalesTerritory (
    TerritoryID       INT          NOT NULL CONSTRAINT PK_stg_SalesTerritory PRIMARY KEY,
    Name              NVARCHAR(50) NOT NULL,
    CountryRegionCode NVARCHAR(3)  NOT NULL,
    TerritoryGroup    NVARCHAR(50) NOT NULL,
    etl_run_id        UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.Customer', N'U') IS NULL
CREATE TABLE stg.Customer (
    CustomerID  INT NOT NULL CONSTRAINT PK_stg_Customer PRIMARY KEY,
    PersonID    INT NULL,
    StoreID     INT NULL,
    TerritoryID INT NULL,
    etl_run_id  UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.Person', N'U') IS NULL
CREATE TABLE stg.Person (
    BusinessEntityID INT          NOT NULL CONSTRAINT PK_stg_Person PRIMARY KEY,
    FirstName        NVARCHAR(50) NOT NULL,
    MiddleName       NVARCHAR(50) NULL,
    LastName         NVARCHAR(50) NOT NULL,
    etl_run_id       UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.SalesPerson', N'U') IS NULL
CREATE TABLE stg.SalesPerson (
    BusinessEntityID INT NOT NULL CONSTRAINT PK_stg_SalesPerson PRIMARY KEY,
    TerritoryID      INT NULL,
    etl_run_id       UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.SalesPersonQuotaHistory', N'U') IS NULL
CREATE TABLE stg.SalesPersonQuotaHistory (
    BusinessEntityID INT           NOT NULL,
    QuotaDate        DATETIME      NOT NULL,
    SalesQuota       DECIMAL(19,4) NOT NULL,
    etl_run_id       UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_stg_SalesPersonQuotaHistory PRIMARY KEY (BusinessEntityID, QuotaDate)
);
GO
IF OBJECT_ID(N'stg.Vendor', N'U') IS NULL
CREATE TABLE stg.Vendor (
    BusinessEntityID INT          NOT NULL CONSTRAINT PK_stg_Vendor PRIMARY KEY,
    Name             NVARCHAR(50) NOT NULL,
    etl_run_id       UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.SalesOrderHeader', N'U') IS NULL
CREATE TABLE stg.SalesOrderHeader (
    SalesOrderID    INT           NOT NULL CONSTRAINT PK_stg_SalesOrderHeader PRIMARY KEY,
    OrderDate       DATETIME      NOT NULL,
    Status          TINYINT       NOT NULL,
    OnlineOrderFlag BIT           NOT NULL,
    CustomerID      INT           NOT NULL,
    SalesPersonID   INT           NULL,
    TerritoryID     INT           NULL,
    SubTotal        DECIMAL(19,4) NOT NULL,
    TaxAmt          DECIMAL(19,4) NOT NULL,
    Freight         DECIMAL(19,4) NOT NULL,
    TotalDue        DECIMAL(19,4) NULL,     -- cot tinh toan o nguon, de NULL-able cho an toan
    etl_run_id      UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.SalesOrderDetail', N'U') IS NULL
CREATE TABLE stg.SalesOrderDetail (
    SalesOrderID       INT           NOT NULL,
    SalesOrderDetailID INT           NOT NULL,
    OrderQty           SMALLINT      NOT NULL,
    ProductID          INT           NOT NULL,
    SpecialOfferID     INT           NOT NULL,
    UnitPrice          DECIMAL(19,4) NOT NULL,
    UnitPriceDiscount  DECIMAL(19,4) NOT NULL,
    LineTotal          DECIMAL(38,6) NULL,  -- cot tinh toan o nguon: NUMERIC(38,6)
    etl_run_id         UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_stg_SalesOrderDetail PRIMARY KEY (SalesOrderID, SalesOrderDetailID)
);
GO
IF OBJECT_ID(N'stg.PurchaseOrderHeader', N'U') IS NULL
CREATE TABLE stg.PurchaseOrderHeader (
    PurchaseOrderID INT      NOT NULL CONSTRAINT PK_stg_PurchaseOrderHeader PRIMARY KEY,
    VendorID        INT      NOT NULL,
    OrderDate       DATETIME NOT NULL,
    Status          TINYINT  NOT NULL,
    etl_run_id      UNIQUEIDENTIFIER NOT NULL
);
GO
IF OBJECT_ID(N'stg.PurchaseOrderDetail', N'U') IS NULL
CREATE TABLE stg.PurchaseOrderDetail (
    PurchaseOrderID       INT           NOT NULL,
    PurchaseOrderDetailID INT           NOT NULL,
    OrderQty              SMALLINT      NOT NULL,
    ProductID             INT           NOT NULL,
    UnitPrice             DECIMAL(19,4) NOT NULL,
    LineTotal             DECIMAL(19,4) NULL,  -- cot tinh toan o nguon
    etl_run_id            UNIQUEIDENTIFIER NOT NULL,
    CONSTRAINT PK_stg_PurchaseOrderDetail PRIMARY KEY (PurchaseOrderID, PurchaseOrderDetailID)
);
GO

-- --------------- Proc tien ich: anh chup stg (dung cho test) ---------------
CREATE OR ALTER PROCEDURE ops.usp_stg_snapshot
    @rows       BIGINT        OUTPUT,
    @amount_sum DECIMAL(38,6) OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    SELECT @rows = COALESCE(SUM(ps.row_count), 0)
    FROM sys.dm_db_partition_stats AS ps
    JOIN sys.tables  AS t ON t.object_id = ps.object_id
    JOIN sys.schemas AS s ON s.schema_id = t.schema_id
    WHERE s.name = N'stg' AND ps.index_id IN (0, 1);

    SELECT @amount_sum =
          COALESCE((SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM stg.SalesOrderDetail), 0)
        + COALESCE((SELECT CAST(SUM(SubTotal)  AS DECIMAL(38,6)) FROM stg.SalesOrderHeader), 0)
        + COALESCE((SELECT CAST(SUM(LineTotal) AS DECIMAL(38,6)) FROM stg.PurchaseOrderDetail), 0);
END;
GO

-- ------------------------- Proc nap toan bo stg -------------------------
CREATE OR ALTER PROCEDURE stg.usp_load_all
    @simulate_fail_after SYSNAME = NULL   -- CHI DUNG CHO TEST (TC-ETL-02): gia lap loi sau khi nap bang nay
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
    DECLARE @objs TABLE (
        seq          INT PRIMARY KEY,
        stg_table    SYSNAME       NOT NULL,
        synonym_name SYSNAME       NOT NULL,
        ins_cols     NVARCHAR(MAX) NOT NULL,
        sel_cols     NVARCHAR(MAX) NOT NULL
    );

    DECLARE @current_step NVARCHAR(128) = N'ops.usp_validate_source';
    DECLARE @step_start   DATETIME2(3)  = SYSUTCDATETIME();
    DECLARE @failed       BIT           = 0;
    DECLARE @err_no       INT;
    DECLARE @err_msg      NVARCHAR(4000);
    DECLARE @final_msg    NVARCHAR(2000);
    DECLARE @m            NVARCHAR(2000);
    DECLARE @i            INT = 1;
    DECLARE @n            INT;
    DECLARE @stg_table    SYSNAME;
    DECLARE @syn          SYSNAME;
    DECLARE @ins          NVARCHAR(MAX);
    DECLARE @sel          NVARCHAR(MAX);
    DECLARE @sql          NVARCHAR(MAX);
    DECLARE @rows_read    INT;
    DECLARE @rows_loaded  INT;

    BEGIN TRY
        -- 1. Kiem tra bang/cot nguon (ngoai transaction)
        EXEC ops.usp_validate_source;

        -- 2. Lap ke hoach nap tu metadata
        INSERT INTO @objs (seq, stg_table, synonym_name, ins_cols, sel_cols)
        SELECT ROW_NUMBER() OVER (ORDER BY o.load_order),
               o.stg_table,
               o.synonym_name,
               (SELECT STRING_AGG(CAST(QUOTENAME(c.stg_column_name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.ordinal)
                  FROM ops.source_column AS c
                 WHERE c.schema_name = o.schema_name AND c.table_name = o.table_name),
               (SELECT STRING_AGG(CAST(QUOTENAME(c.column_name) AS NVARCHAR(MAX)), N', ') WITHIN GROUP (ORDER BY c.ordinal)
                  FROM ops.source_column AS c
                 WHERE c.schema_name = o.schema_name AND c.table_name = o.table_name)
        FROM ops.source_object AS o;

        SET @n = (SELECT COUNT(*) FROM @objs);
        IF @n = 0
        BEGIN
            SET @m = N'ops.source_object rong - chua seed metadata (chay lai 02_schemas_ops.sql).';
            THROW 50012, @m, 1;
        END;

        -- 3. Nap tat ca trong 1 transaction
        BEGIN TRANSACTION;

        WHILE @i <= @n
        BEGIN
            SELECT @stg_table = stg_table, @syn = synonym_name, @ins = ins_cols, @sel = sel_cols
              FROM @objs WHERE seq = @i;

            SET @current_step = N'stg.' + @stg_table;
            SET @step_start   = SYSUTCDATETIME();

            SET @sql = N'SELECT @cnt = COUNT(*) FROM src.' + QUOTENAME(@syn) + N';';
            EXEC sys.sp_executesql @sql, N'@cnt INT OUTPUT', @cnt = @rows_read OUTPUT;

            SET @sql = N'TRUNCATE TABLE stg.' + QUOTENAME(@stg_table) + N'; '
                     + N'INSERT INTO stg.' + QUOTENAME(@stg_table) + N' (' + @ins + N', etl_run_id) '
                     + N'SELECT ' + @sel + N', @run FROM src.' + QUOTENAME(@syn) + N'; '
                     + N'SET @rows = @@ROWCOUNT;';
            EXEC sys.sp_executesql @sql, N'@run UNIQUEIDENTIFIER, @rows INT OUTPUT',
                 @run = @run_id, @rows = @rows_loaded OUTPUT;

            IF @rows_loaded <> @rows_read
            BEGIN
                SET @m = N'Lech so dong tai ' + @current_step + N': nguon ' + CAST(@rows_read AS NVARCHAR(20))
                       + N', da nap ' + CAST(@rows_loaded AS NVARCHAR(20)) + N'.';
                THROW 50021, @m, 1;
            END;

            INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
            VALUES (@current_step, @step_start, SYSUTCDATETIME(), @rows_read, @rows_loaded, 0, 'SUCCESS', NULL, NULL);

            IF @simulate_fail_after IS NOT NULL AND @simulate_fail_after = @stg_table
            BEGIN
                SET @m = N'Simulated failure after ' + @current_step;
                THROW 50099, @m, 1;
            END;

            SET @i = @i + 1;
        END;

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        SET @failed  = 1;
        SET @err_no  = ERROR_NUMBER();
        SET @err_msg = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        -- Cac buoc da nap xong trong transaction nay da bi hoan tac
        UPDATE @steps SET status = 'ROLLED_BACK' WHERE status = 'SUCCESS';

        INSERT INTO @steps (step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
        VALUES (@current_step, @step_start, SYSUTCDATETIME(), 0, 0, 0, 'FAILED', @err_no, @err_msg);
    END CATCH;

    -- 4. Ghi log (ngoai transaction -> luon duoc luu)
    INSERT INTO ops.etl_log (run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message)
    SELECT @run_id, step, start_time, end_time, rows_read, rows_loaded, rows_rejected, status, error_number, error_message
      FROM @steps
     ORDER BY seq;

    -- 5. Bao loi cho nguoi goi
    IF @failed = 1
    BEGIN
        SET @final_msg = LEFT(N'stg.usp_load_all that bai tai buoc ' + @current_step
                            + N' (loi ' + CAST(@err_no AS NVARCHAR(20)) + N'): ' + @err_msg, 2000);
        THROW 50020, @final_msg, 1;
    END;
END;
GO
