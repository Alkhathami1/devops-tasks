#!/usr/bin/env bash
# Schema and data inventory — evidence for requirement 2 (tables and data).

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

echo "=== Schema and data inventory ==="
echo ""

echo "--- database properties ---"
sql "SELECT name AS [database], recovery_model_desc AS [recovery_model],
            page_verify_option_desc AS [page_verify], state_desc AS [state],
            compatibility_level AS [compat]
     FROM sys.databases WHERE name = '${DB_NAME}';"

echo ""
echo "--- tables, with row counts and storage ---"
sql "USE ${DB_NAME};
     SELECT t.name AS [table],
            p.rows AS [row_count],
            CAST(SUM(a.total_pages) * 8.0 / 1024 AS DECIMAL(10,2)) AS [size_mb]
     FROM sys.tables t
     JOIN sys.partitions p ON p.object_id = t.object_id AND p.index_id IN (0,1)
     JOIN sys.allocation_units a ON a.container_id = p.partition_id
     GROUP BY t.name, p.rows
     ORDER BY t.name;"

echo ""
echo "--- foreign keys ---"
sql "USE ${DB_NAME};
     SELECT fk.name AS [constraint],
            OBJECT_NAME(fk.parent_object_id) AS [child_table],
            OBJECT_NAME(fk.referenced_object_id) AS [parent_table],
            fk.delete_referential_action_desc AS [on_delete]
     FROM sys.foreign_keys fk ORDER BY fk.name;"

echo ""
echo "--- check and unique constraints ---"
sql "USE ${DB_NAME};
     SELECT OBJECT_NAME(parent_object_id) AS [table], name AS [check_constraint], definition
     FROM sys.check_constraints ORDER BY [table], name;"

echo ""
echo "--- indexes ---"
sql "USE ${DB_NAME};
     SELECT OBJECT_NAME(i.object_id) AS [table], i.name AS [index],
            i.type_desc AS [type], i.is_unique AS [unique]
     FROM sys.indexes i
     JOIN sys.tables t ON t.object_id = i.object_id
     WHERE i.type > 0 ORDER BY [table], i.name;"

echo ""
echo "--- sample of the data, joined across three tables ---"
sql "USE ${DB_NAME};
     SELECT TOP 8 order_id, full_name, status, line_count, order_total
     FROM dbo.vw_order_summary ORDER BY order_id;"

echo ""
echo "--- state fingerprint ---"
sqlfile "$STACK_DIR/sql/90-state.sql"

echo ""
echo "--- constraints are enforced, not decorative ---"
echo "    attempting an insert that violates CK_products_price (unit_price > 0):"
if sql "USE ${DB_NAME}; INSERT INTO dbo.products (sku, name, unit_price, stock_qty)
        VALUES ('SKU-BAD', 'Negative price', -1.00, 1);" 2>&1 | sed 's/^/      /'; then
  fail "a negative price was accepted; the CHECK constraint is not enforced"
else
  pass "negative price rejected by CK_products_price"
fi

echo "    attempting an order for a customer that does not exist:"
if sql "USE ${DB_NAME}; INSERT INTO dbo.orders (customer_id, status)
        VALUES (999999, 'PENDING');" 2>&1 | sed 's/^/      /'; then
  fail "an orphan order was accepted; the foreign key is not enforced"
else
  pass "orphan order rejected by FK_orders_customer"
fi

echo ""
if [ "$RESULT" = "0" ]; then echo "RESULT: SCHEMA CHECKS PASSED"; else echo "RESULT: SCHEMA CHECKS FAILED"; fi
exit "$RESULT"
