/* =====================================================================
   02_schemas_ops.sql  -  Tao FinanceDW, schema (src/stg/dwh/ops), bang van hanh,
                          metadata nguon, synonym src.*, proc kiem tra nguon
   Chay tren: SSMS (Windows). Chay lai nhieu lan an toan (idempotent).
   LUU Y: ten DB 'FinanceDW' va 'AdventureWorks2022' duoc co dinh trong script.
          Neu doi ten, tim-thay-the o tat ca file trong thu muc sql/ va tests/.
   Phong thu: TC-ENV-03 (thieu bang/cot nguon), TC-ETL-06 (collation).
   ===================================================================== */
USE master;
GO
IF DB_ID(N'FinanceDW') IS NULL
    CREATE DATABASE FinanceDW;   -- dung thu muc mac dinh cua instance
GO
ALTER DATABASE FinanceDW SET RECOVERY SIMPLE;
GO
USE FinanceDW;
GO

-- ------------------------------ Schemas ------------------------------
IF SCHEMA_ID(N'src') IS NULL EXEC (N'CREATE SCHEMA src');   -- synonym tro toi DB goc (chi doc)
IF SCHEMA_ID(N'stg') IS NULL EXEC (N'CREATE SCHEMA stg');   -- ban sao tho cua nguon
IF SCHEMA_ID(N'dwh') IS NULL EXEC (N'CREATE SCHEMA dwh');   -- star schema (Module sau)
IF SCHEMA_ID(N'ops') IS NULL EXEC (N'CREATE SCHEMA ops');   -- log, reject, cau hinh
GO

-- --------------------------- Bang van hanh ---------------------------
-- Thoi gian luu theo UTC.
IF OBJECT_ID(N'ops.etl_log', N'U') IS NULL
CREATE TABLE ops.etl_log (
    log_id         BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_etl_log PRIMARY KEY,
    run_id         UNIQUEIDENTIFIER NOT NULL,
    step           NVARCHAR(128)    NOT NULL,
    start_time     DATETIME2(3)     NOT NULL,
    end_time       DATETIME2(3)     NOT NULL,
    rows_read      INT              NOT NULL CONSTRAINT DF_etl_log_rows_read     DEFAULT 0 CONSTRAINT CK_etl_log_rows_read     CHECK (rows_read     >= 0),
    rows_loaded    INT              NOT NULL CONSTRAINT DF_etl_log_rows_loaded   DEFAULT 0 CONSTRAINT CK_etl_log_rows_loaded   CHECK (rows_loaded   >= 0),
    rows_rejected  INT              NOT NULL CONSTRAINT DF_etl_log_rows_rejected DEFAULT 0 CONSTRAINT CK_etl_log_rows_rejected CHECK (rows_rejected >= 0),
    status         VARCHAR(12)      NOT NULL CONSTRAINT CK_etl_log_status CHECK (status IN ('SUCCESS', 'FAILED', 'ROLLED_BACK')),
    error_number   INT              NULL,
    error_message  NVARCHAR(4000)   NULL,
    CONSTRAINT CK_etl_log_failed_msg CHECK (status <> 'FAILED' OR NULLIF(LTRIM(RTRIM(error_message)), N'') IS NOT NULL)
);
GO

IF OBJECT_ID(N'ops.reject', N'U') IS NULL
CREATE TABLE ops.reject (
    reject_id   BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_reject PRIMARY KEY,
    run_id      UNIQUEIDENTIFIER NOT NULL,
    step        NVARCHAR(128)    NOT NULL,
    source_key  NVARCHAR(200)    NULL,
    reason      NVARCHAR(400)    NOT NULL,
    raw_row     NVARCHAR(MAX)    NULL,
    created_at  DATETIME2(3)     NOT NULL CONSTRAINT DF_reject_created_at DEFAULT SYSUTCDATETIME()
);
GO

IF OBJECT_ID(N'ops.config', N'U') IS NULL
CREATE TABLE ops.config (
    config_key    VARCHAR(50)   NOT NULL CONSTRAINT PK_ops_config PRIMARY KEY,
    config_value  NVARCHAR(500) NOT NULL
);
GO

IF OBJECT_ID(N'ops.source_object', N'U') IS NULL
CREATE TABLE ops.source_object (
    schema_name   SYSNAME NOT NULL,
    table_name    SYSNAME NOT NULL,
    synonym_name  SYSNAME NOT NULL,
    stg_table     SYSNAME NOT NULL,
    load_order    INT     NOT NULL,
    CONSTRAINT PK_source_object PRIMARY KEY (schema_name, table_name),
    CONSTRAINT UQ_source_object_stg   UNIQUE (stg_table),
    CONSTRAINT UQ_source_object_syn   UNIQUE (synonym_name),
    CONSTRAINT UQ_source_object_order UNIQUE (load_order)
);
GO

IF OBJECT_ID(N'ops.source_column', N'U') IS NULL
CREATE TABLE ops.source_column (
    schema_name      SYSNAME NOT NULL,
    table_name       SYSNAME NOT NULL,
    column_name      SYSNAME NOT NULL,
    stg_column_name  SYSNAME NOT NULL,
    ordinal          INT     NOT NULL,
    CONSTRAINT PK_source_column PRIMARY KEY (schema_name, table_name, column_name),
    CONSTRAINT UQ_source_column_ord UNIQUE (schema_name, table_name, ordinal),
    CONSTRAINT FK_source_column_object FOREIGN KEY (schema_name, table_name)
        REFERENCES ops.source_object (schema_name, table_name)
);
GO

-- ------------------- Seed metadata (an toan khi chay lai) -------------------
DELETE FROM ops.source_column;
DELETE FROM ops.source_object;
DELETE FROM ops.config;

INSERT INTO ops.config (config_key, config_value) VALUES ('source_db', N'AdventureWorks2022');

-- load_order: bang chieu (dimension) truoc, bang su kien (fact) sau
INSERT INTO ops.source_object (schema_name, table_name, synonym_name, stg_table, load_order) VALUES
 (N'Production', N'ProductCategory',        N'Production_ProductCategory',        N'ProductCategory',        1),
 (N'Production', N'ProductSubcategory',     N'Production_ProductSubcategory',     N'ProductSubcategory',     2),
 (N'Production', N'Product',                N'Production_Product',                N'Product',                3),
 (N'Production', N'ProductCostHistory',     N'Production_ProductCostHistory',     N'ProductCostHistory',     4),
 (N'Sales',      N'SalesTerritory',         N'Sales_SalesTerritory',              N'SalesTerritory',         5),
 (N'Sales',      N'Customer',               N'Sales_Customer',                    N'Customer',               6),
 (N'Person',     N'Person',                 N'Person_Person',                     N'Person',                 7),
 (N'Sales',      N'SalesPerson',            N'Sales_SalesPerson',                 N'SalesPerson',            8),
 (N'Sales',      N'SalesPersonQuotaHistory',N'Sales_SalesPersonQuotaHistory',     N'SalesPersonQuotaHistory',9),
 (N'Purchasing', N'Vendor',                 N'Purchasing_Vendor',                 N'Vendor',                 10),
 (N'Sales',      N'SalesOrderHeader',       N'Sales_SalesOrderHeader',            N'SalesOrderHeader',       11),
 (N'Sales',      N'SalesOrderDetail',       N'Sales_SalesOrderDetail',            N'SalesOrderDetail',       12),
 (N'Purchasing', N'PurchaseOrderHeader',    N'Purchasing_PurchaseOrderHeader',    N'PurchaseOrderHeader',    13),
 (N'Purchasing', N'PurchaseOrderDetail',    N'Purchasing_PurchaseOrderDetail',    N'PurchaseOrderDetail',    14);

-- (schema, table, cot nguon, cot stg, thu tu). Cot nguon [Group] doi ten thanh TerritoryGroup.
INSERT INTO ops.source_column (schema_name, table_name, column_name, stg_column_name, ordinal) VALUES
 (N'Production', N'ProductCategory',    N'ProductCategoryID',   N'ProductCategoryID',   1),
 (N'Production', N'ProductCategory',    N'Name',                N'Name',                2),

 (N'Production', N'ProductSubcategory', N'ProductSubcategoryID',N'ProductSubcategoryID',1),
 (N'Production', N'ProductSubcategory', N'ProductCategoryID',   N'ProductCategoryID',   2),
 (N'Production', N'ProductSubcategory', N'Name',                N'Name',                3),

 (N'Production', N'Product',            N'ProductID',           N'ProductID',           1),
 (N'Production', N'Product',            N'Name',                N'Name',                2),
 (N'Production', N'Product',            N'ProductNumber',       N'ProductNumber',       3),
 (N'Production', N'Product',            N'StandardCost',        N'StandardCost',        4),
 (N'Production', N'Product',            N'ListPrice',           N'ListPrice',           5),
 (N'Production', N'Product',            N'ProductSubcategoryID',N'ProductSubcategoryID',6),
 (N'Production', N'Product',            N'SellStartDate',       N'SellStartDate',       7),
 (N'Production', N'Product',            N'SellEndDate',         N'SellEndDate',         8),

 (N'Production', N'ProductCostHistory', N'ProductID',           N'ProductID',           1),
 (N'Production', N'ProductCostHistory', N'StartDate',           N'StartDate',           2),
 (N'Production', N'ProductCostHistory', N'EndDate',             N'EndDate',             3),
 (N'Production', N'ProductCostHistory', N'StandardCost',        N'StandardCost',        4),

 (N'Sales',      N'SalesTerritory',     N'TerritoryID',         N'TerritoryID',         1),
 (N'Sales',      N'SalesTerritory',     N'Name',                N'Name',                2),
 (N'Sales',      N'SalesTerritory',     N'CountryRegionCode',   N'CountryRegionCode',   3),
 (N'Sales',      N'SalesTerritory',     N'Group',               N'TerritoryGroup',      4),

 (N'Sales',      N'Customer',           N'CustomerID',          N'CustomerID',          1),
 (N'Sales',      N'Customer',           N'PersonID',            N'PersonID',            2),
 (N'Sales',      N'Customer',           N'StoreID',             N'StoreID',             3),
 (N'Sales',      N'Customer',           N'TerritoryID',         N'TerritoryID',         4),

 (N'Person',     N'Person',             N'BusinessEntityID',    N'BusinessEntityID',    1),
 (N'Person',     N'Person',             N'FirstName',           N'FirstName',           2),
 (N'Person',     N'Person',             N'MiddleName',          N'MiddleName',          3),
 (N'Person',     N'Person',             N'LastName',            N'LastName',            4),

 (N'Sales',      N'SalesPerson',        N'BusinessEntityID',    N'BusinessEntityID',    1),
 (N'Sales',      N'SalesPerson',        N'TerritoryID',         N'TerritoryID',         2),

 (N'Sales',      N'SalesPersonQuotaHistory', N'BusinessEntityID', N'BusinessEntityID',  1),
 (N'Sales',      N'SalesPersonQuotaHistory', N'QuotaDate',        N'QuotaDate',         2),
 (N'Sales',      N'SalesPersonQuotaHistory', N'SalesQuota',       N'SalesQuota',        3),

 (N'Purchasing', N'Vendor',             N'BusinessEntityID',    N'BusinessEntityID',    1),
 (N'Purchasing', N'Vendor',             N'Name',                N'Name',                2),

 (N'Sales',      N'SalesOrderHeader',   N'SalesOrderID',        N'SalesOrderID',        1),
 (N'Sales',      N'SalesOrderHeader',   N'OrderDate',           N'OrderDate',           2),
 (N'Sales',      N'SalesOrderHeader',   N'Status',              N'Status',              3),
 (N'Sales',      N'SalesOrderHeader',   N'OnlineOrderFlag',     N'OnlineOrderFlag',     4),
 (N'Sales',      N'SalesOrderHeader',   N'CustomerID',          N'CustomerID',          5),
 (N'Sales',      N'SalesOrderHeader',   N'SalesPersonID',       N'SalesPersonID',       6),
 (N'Sales',      N'SalesOrderHeader',   N'TerritoryID',         N'TerritoryID',         7),
 (N'Sales',      N'SalesOrderHeader',   N'SubTotal',            N'SubTotal',            8),
 (N'Sales',      N'SalesOrderHeader',   N'TaxAmt',              N'TaxAmt',              9),
 (N'Sales',      N'SalesOrderHeader',   N'Freight',             N'Freight',             10),
 (N'Sales',      N'SalesOrderHeader',   N'TotalDue',            N'TotalDue',            11),

 (N'Sales',      N'SalesOrderDetail',   N'SalesOrderID',        N'SalesOrderID',        1),
 (N'Sales',      N'SalesOrderDetail',   N'SalesOrderDetailID',  N'SalesOrderDetailID',  2),
 (N'Sales',      N'SalesOrderDetail',   N'OrderQty',            N'OrderQty',            3),
 (N'Sales',      N'SalesOrderDetail',   N'ProductID',           N'ProductID',           4),
 (N'Sales',      N'SalesOrderDetail',   N'SpecialOfferID',      N'SpecialOfferID',      5),
 (N'Sales',      N'SalesOrderDetail',   N'UnitPrice',           N'UnitPrice',           6),
 (N'Sales',      N'SalesOrderDetail',   N'UnitPriceDiscount',   N'UnitPriceDiscount',   7),
 (N'Sales',      N'SalesOrderDetail',   N'LineTotal',           N'LineTotal',           8),

 (N'Purchasing', N'PurchaseOrderHeader',N'PurchaseOrderID',     N'PurchaseOrderID',     1),
 (N'Purchasing', N'PurchaseOrderHeader',N'VendorID',            N'VendorID',            2),
 (N'Purchasing', N'PurchaseOrderHeader',N'OrderDate',           N'OrderDate',           3),
 (N'Purchasing', N'PurchaseOrderHeader',N'Status',              N'Status',              4),

 (N'Purchasing', N'PurchaseOrderDetail',N'PurchaseOrderID',     N'PurchaseOrderID',     1),
 (N'Purchasing', N'PurchaseOrderDetail',N'PurchaseOrderDetailID',N'PurchaseOrderDetailID',2),
 (N'Purchasing', N'PurchaseOrderDetail',N'OrderQty',            N'OrderQty',            3),
 (N'Purchasing', N'PurchaseOrderDetail',N'ProductID',           N'ProductID',           4),
 (N'Purchasing', N'PurchaseOrderDetail',N'UnitPrice',           N'UnitPrice',           5),
 (N'Purchasing', N'PurchaseOrderDetail',N'LineTotal',           N'LineTotal',           6);
GO

-- --------------- Synonym src.* tro toi DB nguon (tao lai moi lan) ---------------
DECLARE @src_db SYSNAME = (SELECT config_value FROM ops.config WHERE config_key = 'source_db');
DECLARE @sql NVARCHAR(MAX) = (
    SELECT STRING_AGG(CAST(
        N'IF OBJECT_ID(N''src.' + o.synonym_name + N''', N''SN'') IS NOT NULL DROP SYNONYM src.' + QUOTENAME(o.synonym_name) + N'; '
      + N'CREATE SYNONYM src.' + QUOTENAME(o.synonym_name) + N' FOR '
      + QUOTENAME(@src_db) + N'.' + QUOTENAME(o.schema_name) + N'.' + QUOTENAME(o.table_name) + N';'
        AS NVARCHAR(MAX)), NCHAR(10))
    FROM ops.source_object AS o
);
EXEC sys.sp_executesql @sql;
GO

-- ---------------- Kiem tra bang/cot nguon (TC-ENV-03, TC-ETL-06) ----------------
CREATE OR ALTER PROCEDURE ops.usp_validate_source
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @src SYSNAME = (SELECT config_value FROM ops.config WHERE config_key = 'source_db');
    DECLARE @m1  NVARCHAR(2000);
    DECLARE @m2  NVARCHAR(2000);

    IF @src IS NULL OR DB_ID(@src) IS NULL
    BEGIN
        SET @m1 = N'Khong tim thay database nguon ' + COALESCE(QUOTENAME(@src), N'(ops.config.source_db chua cau hinh)')
                + N'. Chay 01_restore.sql truoc.';
        THROW 50010, @m1, 1;
    END;

    CREATE TABLE #missing (schema_name SYSNAME, table_name SYSNAME, column_name SYSNAME);

    -- COLLATE DATABASE_DEFAULT o hai ve de tranh loi xung dot collation giua hai DB
    DECLARE @sql NVARCHAR(MAX) = N'
        INSERT INTO #missing (schema_name, table_name, column_name)
        SELECT c.schema_name, c.table_name, c.column_name
        FROM ops.source_column AS c
        WHERE NOT EXISTS (
            SELECT 1
            FROM ' + QUOTENAME(@src) + N'.sys.columns AS col
            JOIN ' + QUOTENAME(@src) + N'.sys.tables  AS t ON t.object_id = col.object_id
            JOIN ' + QUOTENAME(@src) + N'.sys.schemas AS s ON s.schema_id = t.schema_id
            WHERE s.name   COLLATE DATABASE_DEFAULT = c.schema_name COLLATE DATABASE_DEFAULT
              AND t.name   COLLATE DATABASE_DEFAULT = c.table_name  COLLATE DATABASE_DEFAULT
              AND col.name COLLATE DATABASE_DEFAULT = c.column_name COLLATE DATABASE_DEFAULT
        );';
    EXEC sys.sp_executesql @sql;

    IF EXISTS (SELECT 1 FROM #missing)
    BEGIN
        SET @m2 = N'Thieu bang/cot trong ' + QUOTENAME(@src) + N': '
                + (SELECT STRING_AGG(CAST(schema_name + N'.' + table_name + N'.' + column_name AS NVARCHAR(MAX)), N', ') FROM #missing);
        SET @m2 = LEFT(@m2, 2000);
        THROW 50011, @m2, 1;
    END;
END;
GO
