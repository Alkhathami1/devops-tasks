/*
 * 03 — Seed data.
 *
 * Volume matters for the restore proof: a handful of rows can be eyeballed,
 * but thousands of rows across four related tables make a checksum comparison
 * meaningful. Roughly 60 customers, 40 products, ~300 orders and ~900 order
 * lines are generated deterministically.
 *
 * Idempotent: every insert is guarded by NOT EXISTS, so re-running seeds
 * nothing. The drills bring the stack up repeatedly and duplicate seed rows
 * would quietly invalidate every row-count assertion afterwards.
 *
 * Determinism: values are derived arithmetically from a numbers table rather
 * than from RAND() or NEWID(), so the same seed always produces byte-identical
 * data and the checksum is comparable across runs.
 */

USE AppDb;
GO

SET NOCOUNT ON;
GO

/* A tally table via a recursive CTE, used to generate rows without loops. */
IF OBJECT_ID('tempdb..#numbers') IS NOT NULL DROP TABLE #numbers;
WITH n AS (
    SELECT 1 AS i
    UNION ALL
    SELECT i + 1 FROM n WHERE i < 1000
)
SELECT i INTO #numbers FROM n OPTION (MAXRECURSION 1000);
GO

/* ------------------------------------------------------------- customers -- */
INSERT INTO dbo.customers (full_name, email, country_code, created_at)
SELECT
    CONCAT('Customer ', RIGHT('000' + CAST(i AS VARCHAR(4)), 3)),
    CONCAT('customer', i, '@example.com'),
    CASE i % 5 WHEN 0 THEN 'SA' WHEN 1 THEN 'GB' WHEN 2 THEN 'US' WHEN 3 THEN 'DE' ELSE 'AE' END,
    DATEADD(DAY, -i, '2026-01-01T00:00:00')
FROM #numbers
WHERE i <= 60
  AND NOT EXISTS (SELECT 1 FROM dbo.customers c WHERE c.email = CONCAT('customer', i, '@example.com'));
GO

/* -------------------------------------------------------------- products -- */
INSERT INTO dbo.products (sku, name, unit_price, stock_qty)
SELECT
    CONCAT('SKU-', RIGHT('0000' + CAST(i AS VARCHAR(5)), 4)),
    CONCAT('Product ', i),
    CAST((i * 7 % 400) + 5.50 AS DECIMAL(10,2)),   /* always > 0, satisfies CK_products_price */
    (i * 13) % 250
FROM #numbers
WHERE i <= 40
  AND NOT EXISTS (SELECT 1 FROM dbo.products p WHERE p.sku = CONCAT('SKU-', RIGHT('0000' + CAST(i AS VARCHAR(5)), 4)));
GO

/* ---------------------------------------------------------------- orders -- */
/* Each order is tied to a customer by modulo, giving a realistic spread of
   1-6 orders per customer. Guarded by a count check so re-running adds none. */
INSERT INTO dbo.orders (customer_id, order_date, status)
SELECT
    c.customer_id,
    DATEADD(HOUR, -(n.i * 7), '2026-06-01T12:00:00'),
    CASE n.i % 4 WHEN 0 THEN 'PENDING' WHEN 1 THEN 'PAID' WHEN 2 THEN 'SHIPPED' ELSE 'CANCELLED' END
FROM #numbers n
JOIN dbo.customers c ON c.customer_id = ((n.i - 1) % 60) + 1
WHERE n.i <= 300
  AND NOT EXISTS (SELECT 1 FROM dbo.orders o);   /* seed once only */
GO

/* ----------------------------------------------------------- order_items -- */
/* Two or three lines per order, distinct products per order to satisfy
   UQ_items_order_product. */
INSERT INTO dbo.order_items (order_id, product_id, quantity, unit_price)
SELECT
    o.order_id,
    p.product_id,
    ((o.order_id + p.product_id) % 5) + 1,
    p.unit_price
FROM dbo.orders o
CROSS APPLY (
    SELECT TOP (CASE WHEN o.order_id % 2 = 0 THEN 3 ELSE 2 END) product_id, unit_price
    FROM dbo.products
    WHERE product_id >= ((o.order_id * 3) % 38) + 1
    ORDER BY product_id
) p
WHERE NOT EXISTS (SELECT 1 FROM dbo.order_items oi);   /* seed once only */
GO

DROP TABLE #numbers;
GO

PRINT 'Seed complete.';
GO

SELECT 'customers' AS [table], COUNT(*) AS [rows] FROM dbo.customers
UNION ALL SELECT 'products',   COUNT(*) FROM dbo.products
UNION ALL SELECT 'orders',     COUNT(*) FROM dbo.orders
UNION ALL SELECT 'order_items',COUNT(*) FROM dbo.order_items;
GO
