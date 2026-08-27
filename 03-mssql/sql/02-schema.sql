/*
 * 02 — Schema: four related tables with foreign keys, indexes and constraints.
 *
 * Domain: a small order-management system. Chosen over a single toy table
 * because a restore is only convincing if referential integrity has to survive
 * it: a backup that restores rows but breaks the parent/child relationships
 * would pass a naive row-count check and still be worthless.
 *
 * Idempotent throughout: every object is guarded, so re-running is a no-op.
 */

USE AppDb;
GO

/* ---------------------------------------------------------------- customers */
IF OBJECT_ID('dbo.customers', 'U') IS NULL
BEGIN
    PRINT 'Creating dbo.customers';
    CREATE TABLE dbo.customers (
        customer_id   INT            IDENTITY(1,1) NOT NULL,
        full_name     NVARCHAR(120)  NOT NULL,
        email         NVARCHAR(200)  NOT NULL,
        country_code  CHAR(2)        NOT NULL,
        created_at    DATETIME2(3)   NOT NULL CONSTRAINT DF_customers_created DEFAULT SYSUTCDATETIME(),
        CONSTRAINT PK_customers PRIMARY KEY CLUSTERED (customer_id),
        CONSTRAINT UQ_customers_email UNIQUE (email),
        CONSTRAINT CK_customers_email_shape CHECK (email LIKE '%_@_%.__%'),
        CONSTRAINT CK_customers_country CHECK (country_code = UPPER(country_code))
    );
END
GO

/* ----------------------------------------------------------------- products */
IF OBJECT_ID('dbo.products', 'U') IS NULL
BEGIN
    PRINT 'Creating dbo.products';
    CREATE TABLE dbo.products (
        product_id   INT            IDENTITY(1,1) NOT NULL,
        sku          VARCHAR(32)    NOT NULL,
        name         NVARCHAR(160)  NOT NULL,
        unit_price   DECIMAL(10,2)  NOT NULL,
        stock_qty    INT            NOT NULL CONSTRAINT DF_products_stock DEFAULT 0,
        CONSTRAINT PK_products PRIMARY KEY CLUSTERED (product_id),
        CONSTRAINT UQ_products_sku UNIQUE (sku),
        /* Money must be positive; stock may be zero but never negative. */
        CONSTRAINT CK_products_price CHECK (unit_price > 0),
        CONSTRAINT CK_products_stock CHECK (stock_qty >= 0)
    );
END
GO

/* ------------------------------------------------------------------- orders */
IF OBJECT_ID('dbo.orders', 'U') IS NULL
BEGIN
    PRINT 'Creating dbo.orders';
    CREATE TABLE dbo.orders (
        order_id     INT           IDENTITY(1,1) NOT NULL,
        customer_id  INT           NOT NULL,
        order_date   DATETIME2(3)  NOT NULL CONSTRAINT DF_orders_date DEFAULT SYSUTCDATETIME(),
        status       VARCHAR(16)   NOT NULL CONSTRAINT DF_orders_status DEFAULT 'PENDING',
        CONSTRAINT PK_orders PRIMARY KEY CLUSTERED (order_id),
        /* NO ACTION, not CASCADE: deleting a customer with live orders should
           fail loudly rather than silently destroy order history. */
        CONSTRAINT FK_orders_customer FOREIGN KEY (customer_id)
            REFERENCES dbo.customers (customer_id) ON DELETE NO ACTION,
        CONSTRAINT CK_orders_status CHECK (status IN ('PENDING','PAID','SHIPPED','CANCELLED'))
    );
END
GO

/* -------------------------------------------------------------- order_items */
IF OBJECT_ID('dbo.order_items', 'U') IS NULL
BEGIN
    PRINT 'Creating dbo.order_items';
    CREATE TABLE dbo.order_items (
        order_item_id INT           IDENTITY(1,1) NOT NULL,
        order_id      INT           NOT NULL,
        product_id    INT           NOT NULL,
        quantity      INT           NOT NULL,
        unit_price    DECIMAL(10,2) NOT NULL,
        CONSTRAINT PK_order_items PRIMARY KEY CLUSTERED (order_item_id),
        /* CASCADE here is correct: an order line has no meaning without its
           order, so removing the order should take its lines with it. */
        CONSTRAINT FK_items_order FOREIGN KEY (order_id)
            REFERENCES dbo.orders (order_id) ON DELETE CASCADE,
        CONSTRAINT FK_items_product FOREIGN KEY (product_id)
            REFERENCES dbo.products (product_id) ON DELETE NO ACTION,
        CONSTRAINT CK_items_quantity CHECK (quantity > 0),
        CONSTRAINT CK_items_price CHECK (unit_price >= 0),
        /* The same product must not appear twice on one order. */
        CONSTRAINT UQ_items_order_product UNIQUE (order_id, product_id)
    );
END
GO

/* -------------------------------------------------------------- indexes ---
 * Foreign key columns are indexed deliberately. SQL Server creates an index
 * for a PRIMARY KEY and a UNIQUE constraint but NOT for a foreign key, so
 * without these every join from parent to child, and every referential
 * integrity check on delete, is a scan.
 */
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_orders_customer' AND object_id = OBJECT_ID('dbo.orders'))
    CREATE NONCLUSTERED INDEX IX_orders_customer ON dbo.orders (customer_id) INCLUDE (order_date, status);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_orders_date' AND object_id = OBJECT_ID('dbo.orders'))
    CREATE NONCLUSTERED INDEX IX_orders_date ON dbo.orders (order_date);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_items_order' AND object_id = OBJECT_ID('dbo.order_items'))
    CREATE NONCLUSTERED INDEX IX_items_order ON dbo.order_items (order_id);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_items_product' AND object_id = OBJECT_ID('dbo.order_items'))
    CREATE NONCLUSTERED INDEX IX_items_product ON dbo.order_items (product_id);
GO

/* A view used by the verification scripts to summarise state in one query. */
IF OBJECT_ID('dbo.vw_order_summary', 'V') IS NOT NULL
    DROP VIEW dbo.vw_order_summary;
GO
CREATE VIEW dbo.vw_order_summary AS
SELECT
    o.order_id,
    c.full_name,
    c.email,
    o.status,
    o.order_date,
    COUNT(oi.order_item_id)                      AS line_count,
    SUM(oi.quantity * oi.unit_price)             AS order_total
FROM dbo.orders o
JOIN dbo.customers  c  ON c.customer_id = o.customer_id
LEFT JOIN dbo.order_items oi ON oi.order_id = o.order_id
GROUP BY o.order_id, c.full_name, c.email, o.status, o.order_date;
GO

PRINT 'Schema ready.';
GO

SELECT
    t.name                                   AS [table],
    (SELECT COUNT(*) FROM sys.foreign_keys f WHERE f.parent_object_id = t.object_id) AS [foreign_keys],
    (SELECT COUNT(*) FROM sys.check_constraints k WHERE k.parent_object_id = t.object_id) AS [check_constraints],
    (SELECT COUNT(*) FROM sys.indexes i WHERE i.object_id = t.object_id AND i.type > 0)   AS [indexes]
FROM sys.tables t
WHERE t.name IN ('customers','products','orders','order_items')
ORDER BY t.name;
GO
