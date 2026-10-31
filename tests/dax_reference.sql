/* =====================================================================
   tests/dax_reference.sql  -  TC-DAX-04: so lieu "dap an" tu SQL de doi chieu voi measure DAX
   Chay tren FinanceDW. So sanh tung cot voi Matrix (hang = dim_date[year]) trong Power BI.
   Quy tac: lech toi da 0.01 (lam tron hien thi) -> coi la KHOP.
   ===================================================================== */
USE FinanceDW;
SET NOCOUNT ON;

SELECT d.[year]                                                       AS [year],
       CAST(SUM(f.revenue)      AS DECIMAL(19,2))                     AS revenue,
       CAST(SUM(f.cogs)         AS DECIMAL(19,2))                     AS cogs,
       CAST(SUM(f.gross_profit) AS DECIMAL(19,2))                     AS gross_profit,
       CAST(100.0 * SUM(f.gross_profit) / NULLIF(SUM(f.revenue), 0) AS DECIMAL(19,2)) AS gross_margin_pct,
       CAST(SUM(f.discount_amt) AS DECIMAL(19,2))                     AS discount_amount,
       COUNT(DISTINCT f.sales_order_id)                               AS orders,
       SUM(f.order_qty)                                               AS units_sold,
       CAST(SUM(f.revenue) / NULLIF(COUNT(DISTINCT f.sales_order_id), 0) AS DECIMAL(19,2)) AS avg_order_value
  FROM dwh.fact_sales AS f
  JOIN dwh.dim_date   AS d ON d.date_key = f.date_key
 GROUP BY d.[year]
 ORDER BY d.[year];

-- Mua hang va quota theo nam
SELECT COALESCE(p.[year], q.[year]) AS [year], p.purchase_amount, p.purchase_orders, q.quota_amount
  FROM (SELECT d.[year], CAST(SUM(f.line_total) AS DECIMAL(19,2)) AS purchase_amount,
               COUNT(DISTINCT f.purchase_order_id) AS purchase_orders
          FROM dwh.fact_purchasing AS f JOIN dwh.dim_date AS d ON d.date_key = f.date_key GROUP BY d.[year]) AS p
  FULL OUTER JOIN
       (SELECT d.[year], CAST(SUM(f.quota_amount) AS DECIMAL(19,2)) AS quota_amount
          FROM dwh.fact_quota AS f JOIN dwh.dim_date AS d ON d.date_key = f.date_key GROUP BY d.[year]) AS q
    ON q.[year] = p.[year]
 ORDER BY 1;

-- YoY % theo nam (chi nam du du lieu va co nam truoc): so voi cot "Revenue YoY %" (x100)
;WITH y AS (
    SELECT d.[year], SUM(f.revenue) AS revenue, MIN(CAST(d.is_year_complete AS INT)) AS is_year_complete
      FROM dwh.fact_sales AS f JOIN dwh.dim_date AS d ON d.date_key = f.date_key GROUP BY d.[year]
)
SELECT c.[year], c.is_year_complete,
       CAST(100.0 * (c.revenue - p.revenue) / NULLIF(p.revenue, 0) AS DECIMAL(19,2)) AS yoy_pct_expected
  FROM y AS c LEFT JOIN y AS p ON p.[year] = c.[year] - 1
 ORDER BY c.[year];

-- Quota attainment theo nam (chi nhan vien that): actual = revenue salesperson_key <> -1
SELECT a.[year], CAST(a.actual AS DECIMAL(19,2)) AS actual_reps, CAST(q.quota AS DECIMAL(19,2)) AS quota,
       CAST(100.0 * a.actual / NULLIF(q.quota, 0) AS DECIMAL(19,2)) AS attainment_pct
  FROM (SELECT d.[year], SUM(f.revenue) AS actual FROM dwh.fact_sales AS f JOIN dwh.dim_date AS d ON d.date_key = f.date_key
         WHERE f.salesperson_key <> -1 GROUP BY d.[year]) AS a
  JOIN (SELECT d.[year], SUM(f.quota_amount) AS quota FROM dwh.fact_quota AS f JOIN dwh.dim_date AS d ON d.date_key = f.date_key
         GROUP BY d.[year]) AS q ON q.[year] = a.[year]
 ORDER BY a.[year];

-- Co ky chua du du lieu (de doi chieu Period Status)
SELECT [year], MIN(CAST(is_month_complete AS INT)) AS all_months_complete, MIN(CAST(is_year_complete AS INT)) AS year_complete
  FROM dwh.dim_date GROUP BY [year] ORDER BY [year];
