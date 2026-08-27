/*
 * 90 — Database state fingerprint.
 *
 * Emits one deterministic line per table plus a combined fingerprint, so a
 * pre-damage and post-restore state can be compared exactly rather than
 * eyeballed.
 *
 * Why not row counts alone: a restore that returned the right NUMBER of rows
 * with the wrong CONTENT would pass a count check. CHECKSUM_AGG over each
 * row's BINARY_CHECKSUM detects changed values, and the numeric aggregates
 * catch the (unlikely but real) case of checksum collisions cancelling out.
 *
 * Deliberately avoids anything time-dependent so the fingerprint is stable
 * across runs of identical data.
 */

USE AppDb;
GO
SET NOCOUNT ON;
GO

SELECT
    'customers'                                        AS [table],
    COUNT_BIG(*)                                       AS [rows],
    ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)), 0)        AS [checksum],
    ISNULL(SUM(CAST(customer_id AS BIGINT)), 0)        AS [id_sum]
FROM dbo.customers
UNION ALL
SELECT 'products', COUNT_BIG(*), ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)), 0),
       ISNULL(CAST(SUM(unit_price * 100) AS BIGINT), 0)
FROM dbo.products
UNION ALL
SELECT 'orders', COUNT_BIG(*), ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)), 0),
       ISNULL(SUM(CAST(customer_id AS BIGINT)), 0)
FROM dbo.orders
UNION ALL
SELECT 'order_items', COUNT_BIG(*), ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)), 0),
       ISNULL(CAST(SUM(quantity * unit_price * 100) AS BIGINT), 0)
FROM dbo.order_items;
GO

/* Single combined fingerprint, easy for a shell script to capture and diff. */
SELECT CONCAT(
    'FINGERPRINT:',
    (SELECT COUNT_BIG(*) FROM dbo.customers),   '|',
    (SELECT COUNT_BIG(*) FROM dbo.products),    '|',
    (SELECT COUNT_BIG(*) FROM dbo.orders),      '|',
    (SELECT COUNT_BIG(*) FROM dbo.order_items), '|',
    (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.customers),   '|',
    (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.products),    '|',
    (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.orders),      '|',
    (SELECT ISNULL(CHECKSUM_AGG(BINARY_CHECKSUM(*)),0) FROM dbo.order_items), '|',
    (SELECT ISNULL(CAST(SUM(quantity * unit_price * 100) AS BIGINT),0) FROM dbo.order_items)
) AS fingerprint;
GO

/* Referential integrity must survive a restore, not just row counts. */
SELECT CONCAT(
    'ORPHANS:',
    (SELECT COUNT_BIG(*) FROM dbo.orders o
        WHERE NOT EXISTS (SELECT 1 FROM dbo.customers c WHERE c.customer_id = o.customer_id)), '|',
    (SELECT COUNT_BIG(*) FROM dbo.order_items oi
        WHERE NOT EXISTS (SELECT 1 FROM dbo.orders o WHERE o.order_id = oi.order_id)), '|',
    (SELECT COUNT_BIG(*) FROM dbo.order_items oi
        WHERE NOT EXISTS (SELECT 1 FROM dbo.products p WHERE p.product_id = oi.product_id))
) AS orphan_check;
GO
