#!/usr/bin/env bash
# validate.sh — End-to-end pipeline validation
# Tests: INSERT → CDC → Flink → Iceberg → Trino, UPDATE flow, DELETE tombstone
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
PASS=0; FAIL=0

pass() { echo -e "${GREEN}[PASS]${NC} $*"; PASS=$((PASS + 1)); }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAIL=$((FAIL + 1)); }
info() { echo -e "${YELLOW}[INFO]${NC} $*"; }

pg()    { docker exec -e PGPASSWORD=lakepass postgres \
            psql -U lakeuser -d lakedb -t -A -c "$1"; }
trino() { docker exec trino trino \
            --server http://localhost:8080 \
            --output-format TSV \
            --execute "$1" 2>/dev/null | tail -1 | tr -d '[:space:]'; }
ch()    { curl -sf "http://localhost:8123/" \
            --data-urlencode "query=$1" | tr -d '[:space:]'; }

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Lakehouse POC — End-to-End Validation"
echo "════════════════════════════════════════════════════════"
echo ""

# ─── Pick an existing customer for delete test ───────────────────────────
CUSTOMER_ID=$(pg "SELECT id FROM customers ORDER BY id DESC LIMIT 1;" | tr -d '[:space:]')
if [ -z "$CUSTOMER_ID" ]; then
  fail "Could not retrieve a customer id from PostgreSQL"
  echo "Cannot proceed without test data."
  exit 1
fi
info "Using customer_id=${CUSTOMER_ID} for delete tombstone test"

# ═══════════════════════════════════════════════════════════════════════════
# TEST 1 — INSERT a new order and confirm it flows to Iceberg
# ═══════════════════════════════════════════════════════════════════════════
info "TEST 1: INSERT new order"

# Find a valid product (not tied to delete-test customer to avoid FK issues)
PRODUCT_ID=$(pg "SELECT id FROM products ORDER BY id LIMIT 1;" | tr -d '[:space:]')
C_ID=$(pg "SELECT id FROM customers WHERE id != ${CUSTOMER_ID} ORDER BY id LIMIT 1;" | tr -d '[:space:]')

INSERT_ID=$(pg "INSERT INTO orders (customer_id, product_id, quantity, total_amount, status) \
  VALUES (${C_ID}, ${PRODUCT_ID}, 3, 999.00, 'pending') RETURNING id;" | head -1 | tr -d '[:space:]')

info "Inserted order id=${INSERT_ID}. Waiting 30s for CDC propagation..."
sleep 30

COUNT=$(trino "SELECT count(*) FROM iceberg.bronze.orders WHERE id = ${INSERT_ID}" || echo "0")
if [ "${COUNT:-0}" = "1" ]; then
  pass "New order (id=${INSERT_ID}) found in iceberg.bronze.orders"
else
  fail "New order (id=${INSERT_ID}) NOT found in iceberg.bronze.orders (count=${COUNT})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 2 — ClickHouse aggregation check
# ═══════════════════════════════════════════════════════════════════════════
info "TEST 2: ClickHouse order_agg data"

# Ensure table exists and refresh data from gold view
ch "CREATE TABLE IF NOT EXISTS default.order_agg (city String, total_revenue Float64, order_count UInt64, avg_order_value Float64) ENGINE = MergeTree() ORDER BY city" > /dev/null 2>&1
ch "TRUNCATE TABLE default.order_agg" > /dev/null 2>&1
docker exec trino trino --server http://localhost:8080 --execute "
  INSERT INTO clickhouse.default.order_agg
  SELECT city, CAST(total_revenue AS DOUBLE), CAST(order_count AS BIGINT), CAST(avg_order_value AS DOUBLE)
  FROM iceberg.gold.order_summary
" 2>/dev/null || info "ClickHouse population from gold view failed (views may not exist yet)"

CH_COUNT=$(ch "SELECT count(*) FROM default.order_agg" || echo "0")
if [ "${CH_COUNT:-0}" -gt 0 ] 2>/dev/null; then
  pass "ClickHouse order_agg contains data (${CH_COUNT} rows)"
else
  fail "ClickHouse order_agg is empty or inaccessible (count=${CH_COUNT})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 3 — UPDATE order status and confirm propagation
# ═══════════════════════════════════════════════════════════════════════════
info "TEST 3: UPDATE order status (id=${INSERT_ID})"

pg "UPDATE orders SET status = 'shipped', updated_at = NOW() WHERE id = ${INSERT_ID};" > /dev/null
info "Updated order status to 'shipped'. Waiting 90s for checkpoint flush..."
sleep 90

STATUS=$(trino "SELECT status FROM iceberg.bronze.orders WHERE id = ${INSERT_ID} ORDER BY updated_at DESC LIMIT 1" || echo "")
if [ "$STATUS" = "shipped" ]; then
  pass "Updated order status is 'shipped' in iceberg.bronze.orders"
else
  fail "Order status mismatch in iceberg.bronze.orders (got '${STATUS}', expected 'shipped')"
fi

# ═══════════════════════════════════════════════════════════════════════════
# TEST 4 — DELETE customer and confirm __op=d tombstone in Iceberg
# ═══════════════════════════════════════════════════════════════════════════
info "TEST 4: DELETE customer (id=${CUSTOMER_ID}) and check tombstone"

# Nullify foreign keys first (orders may reference this customer)
pg "UPDATE orders SET customer_id = ${C_ID} WHERE customer_id = ${CUSTOMER_ID};" > /dev/null
pg "DELETE FROM customers WHERE id = ${CUSTOMER_ID};" > /dev/null
info "Deleted customer id=${CUSTOMER_ID}. Waiting 30s for tombstone propagation..."
sleep 30

TOMBSTONE=$(trino "SELECT count(*) FROM iceberg.bronze.customers WHERE id = ${CUSTOMER_ID} AND __op = 'd'" || echo "0")
if [ "${TOMBSTONE:-0}" -ge 1 ]; then
  pass "Delete tombstone (__op=d) found for customer id=${CUSTOMER_ID} in iceberg.bronze.customers"
else
  fail "Delete tombstone NOT found for customer id=${CUSTOMER_ID} in iceberg.bronze.customers (count=${TOMBSTONE})"
fi

# ═══════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════════════════════"
echo "  Results: ${PASS} PASS  /  ${FAIL} FAIL"
echo "════════════════════════════════════════════════════════"
echo ""

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
