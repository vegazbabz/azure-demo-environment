-- ─────────────────────────────────────────────────────────────────────────────
-- ADE Demo Data — PostgreSQL seed script
-- Targets: ${prefix}db  (deployed by databases.bicep)
-- Run via seed-data.ps1 or: az postgres flexible-server execute ...
-- Script is idempotent — safe to run multiple times.
-- ─────────────────────────────────────────────────────────────────────────────

-- Demo products table
CREATE TABLE IF NOT EXISTS demo_products (
    id          SERIAL PRIMARY KEY,
    name        VARCHAR(100) NOT NULL,
    category    VARCHAR(50)  NOT NULL,
    price       NUMERIC(10,2) NOT NULL,
    stock       INTEGER       NOT NULL DEFAULT 0,
    sku         VARCHAR(30)   UNIQUE NOT NULL,
    created_at  TIMESTAMP     NOT NULL DEFAULT NOW()
);

-- Idempotent insert — skip rows that already exist by SKU
INSERT INTO demo_products (name, category, price, stock, sku)
SELECT name, category, price, stock, sku FROM (VALUES
    ('Widget Alpha',   'hardware', 19.99, 250, 'WGT-ALPHA'),
    ('Widget Beta',    'hardware', 49.99, 120, 'WGT-BETA'),
    ('Service Pack A', 'software', 99.00,   0, 'SVC-PACK-A'),
    ('Connector Kit',  'hardware',  9.99, 500, 'CON-KIT-01'),
    ('Support Bundle', 'services',199.00,   0, 'SPT-BUNDLE')
) AS v(name, category, price, stock, sku)
WHERE NOT EXISTS (
    SELECT 1 FROM demo_products WHERE sku = v.sku
);

-- Demo orders table
CREATE TABLE IF NOT EXISTS demo_orders (
    id            SERIAL PRIMARY KEY,
    customer_id   INTEGER      NOT NULL,
    product_sku   VARCHAR(30)  NOT NULL,
    quantity      INTEGER      NOT NULL DEFAULT 1,
    total         NUMERIC(10,2) NOT NULL,
    status        VARCHAR(20)  NOT NULL DEFAULT 'pending',
    ordered_at    TIMESTAMP    NOT NULL DEFAULT NOW()
);

INSERT INTO demo_orders (customer_id, product_sku, quantity, total, status)
SELECT customer_id, product_sku, quantity, total, status FROM (VALUES
    (1, 'WGT-ALPHA',   2,  39.98, 'completed'),
    (2, 'WGT-BETA',    5, 249.95, 'pending'),
    (1, 'SVC-PACK-A',  1,  99.00, 'shipped'),
    (3, 'CON-KIT-01', 10,  99.90, 'completed'),
    (2, 'SPT-BUNDLE',  1, 199.00, 'pending')
) AS v(customer_id, product_sku, quantity, total, status)
WHERE NOT EXISTS (
    SELECT 1 FROM demo_orders
    WHERE customer_id = v.customer_id
      AND product_sku = v.product_sku
      AND status      = v.status
);

-- Summary
SELECT
    p.category,
    COUNT(o.id)    AS order_count,
    SUM(o.total)   AS revenue
FROM demo_orders o
JOIN demo_products p ON p.sku = o.product_sku
GROUP BY p.category
ORDER BY revenue DESC;
