#!/usr/bin/env bash
# create-views.sh — Create Trino silver and gold views over Iceberg bronze tables
# Views live in the 'lakehouse' memory catalog (Iceberg REST doesn't support views)
set -uo pipefail

TRINO_HOST="${TRINO_HOST:-localhost}"
TRINO_PORT="${TRINO_PORT:-8080}"

trino_exec() {
  if ! trino --server "http://${TRINO_HOST}:${TRINO_PORT}" --execute "$1" 2>&1; then
    echo "[create-views] WARNING: command failed, continuing..."
  fi
}

echo "[create-views] Creating schemas in memory catalog..."
trino_exec "CREATE SCHEMA IF NOT EXISTS lakehouse.silver"
trino_exec "CREATE SCHEMA IF NOT EXISTS lakehouse.gold"

echo "[create-views] Creating silver.customers..."
trino_exec "
CREATE OR REPLACE VIEW lakehouse.silver.customers AS
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM iceberg.bronze.customers
  WHERE __op != 'd'
)
SELECT id, name, email, city, created_at, updated_at, __op
FROM ranked
WHERE rn = 1
"

echo "[create-views] Creating silver.products..."
trino_exec "
CREATE OR REPLACE VIEW lakehouse.silver.products AS
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM iceberg.bronze.products
  WHERE __op != 'd'
)
SELECT id, name, category, price, stock, created_at, updated_at, __op
FROM ranked
WHERE rn = 1
"

echo "[create-views] Creating silver.orders..."
trino_exec "
CREATE OR REPLACE VIEW lakehouse.silver.orders AS
WITH ranked AS (
  SELECT *,
         ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC) AS rn
  FROM iceberg.bronze.orders
  WHERE __op != 'd'
)
SELECT id, customer_id, product_id, quantity, total_amount, status, created_at, updated_at, __op
FROM ranked
WHERE rn = 1
"

echo "[create-views] Creating gold.order_summary..."
trino_exec "
CREATE OR REPLACE VIEW lakehouse.gold.order_summary AS
SELECT
  c.city,
  SUM(o.total_amount)  AS total_revenue,
  COUNT(o.id)          AS order_count,
  AVG(o.total_amount)  AS avg_order_value
FROM lakehouse.silver.orders o
JOIN lakehouse.silver.customers c ON o.customer_id = c.id
GROUP BY c.city
"

echo "[create-views] All views created."
