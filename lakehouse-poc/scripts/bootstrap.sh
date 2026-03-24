#!/usr/bin/env bash
# bootstrap.sh — Full lakehouse POC bootstrap for Ubuntu 22.04
# Usage: bash scripts/bootstrap.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
info()  { echo -e "${GREEN}[bootstrap]${NC} $*"; }
warn()  { echo -e "${YELLOW}[bootstrap]${NC} $*"; }
error() { echo -e "${RED}[bootstrap] ERROR:${NC} $*" >&2; exit 1; }

# ═══════════════════════════════════════════════════════════════════════════
# STEP 1 — Install Docker Engine + Compose plugin
# ═══════════════════════════════════════════════════════════════════════════
install_docker() {
  if command -v docker &>/dev/null; then
    info "Docker already installed ($(docker --version)). Skipping."
    return
  fi
  info "Installing Docker Engine..."
  sudo apt-get update -qq
  sudo apt-get install -y -qq ca-certificates curl gnupg lsb-release
  sudo install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
    | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  sudo chmod a+r /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
     https://download.docker.com/linux/ubuntu \
     $(lsb_release -cs) stable" \
    | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
  sudo apt-get update -qq
  sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  sudo usermod -aG docker "$USER" || true
  info "Docker installed: $(docker --version)"
  info "Docker Compose: $(docker compose version)"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — Install Java 11 + Maven 3.8
# ═══════════════════════════════════════════════════════════════════════════
install_java_maven() {
  if command -v java &>/dev/null && java -version 2>&1 | grep -q '11\.'; then
    info "Java 11 already installed. Skipping."
  else
    info "Installing OpenJDK 11..."
    sudo apt-get update -qq
    sudo apt-get install -y -qq openjdk-11-jdk
    export JAVA_HOME=$(dirname $(dirname $(readlink -f $(which java))))
    info "Java: $(java -version 2>&1 | head -1)"
  fi

  if command -v mvn &>/dev/null; then
    info "Maven already installed ($(mvn --version | head -1)). Skipping."
  else
    info "Installing Maven 3.9..."
    sudo apt-get install -y -qq maven
    info "Maven: $(mvn --version | head -1)"
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# Utility: wait for a container to report 'healthy'
# ═══════════════════════════════════════════════════════════════════════════
wait_healthy() {
  local name="$1"
  local max="${2:-120}"
  local elapsed=0
  info "Waiting for ${name} to be healthy..."
  while true; do
    status=$(docker inspect --format='{{.State.Health.Status}}' "$name" 2>/dev/null || echo "none")
    if [ "$status" = "healthy" ]; then
      info "${name} is healthy."
      return 0
    fi
    if [ $elapsed -ge $max ]; then
      error "${name} did not become healthy within ${max}s (status: ${status})"
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
}

# Wait for a container that has no health check by polling a URL
wait_url() {
  local label="$1"; local url="$2"; local max="${3:-120}"
  local elapsed=0
  info "Waiting for ${label} at ${url} ..."
  while ! curl -sf "$url" > /dev/null 2>&1; do
    if [ $elapsed -ge $max ]; then
      error "${label} did not respond within ${max}s"
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
  info "${label} is up."
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — Start all services
# ═══════════════════════════════════════════════════════════════════════════
start_services() {
  info "Starting all services with Docker Compose..."
  cd "$PROJECT_DIR"
  sudo docker compose up -d 2>&1 || docker compose up -d 2>&1

  # Wait for core services in dependency order
  wait_healthy postgres     180
  wait_healthy zookeeper    120
  wait_healthy kafka        180
  wait_healthy minio        120
  # minio-init is a one-shot container; wait for it to exit successfully
  info "Waiting for minio-init to complete..."
  timeout 120 bash -c '
    until [ "$(docker inspect --format="{{.State.Status}}" minio-init 2>/dev/null)" = "exited" ]; do
      sleep 3
    done
    EC=$(docker inspect --format="{{.State.ExitCode}}" minio-init)
    [ "$EC" = "0" ] && echo "minio-init: done" || (echo "minio-init failed (exit $EC)" && exit 1)
  ' || error "minio-init did not complete successfully"
  wait_healthy iceberg-rest  120
  wait_healthy kafka-connect 300
  wait_healthy flink-jobmanager 120
  wait_healthy trino         180
  wait_healthy clickhouse    120
  wait_healthy superset      240
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 4 — Register Debezium connector
# ═══════════════════════════════════════════════════════════════════════════
register_connector() {
  info "Registering Debezium connector..."
  bash "${SCRIPT_DIR}/register-connector.sh"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5 — Build Flink fat JAR
# ═══════════════════════════════════════════════════════════════════════════
build_flink_jar() {
  info "Building Flink fat JAR..."
  cd "$PROJECT_DIR"
  mvn package -f flink-jobs/pom.xml -DskipTests -q
  FAR_JAR=$(find flink-jobs/target -name "*-fat.jar" | head -1)
  if [ -z "$FAR_JAR" ]; then
    error "Fat JAR not found after Maven build"
  fi
  info "Built: ${FAR_JAR}"
  echo "$FAR_JAR"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6 — Submit Flink JAR to JobManager
# ═══════════════════════════════════════════════════════════════════════════
submit_flink_job() {
  local fat_jar="$1"
  local flink_url="http://localhost:8082"
  info "Submitting Flink job from ${fat_jar} ..."

  # Upload JAR
  UPLOAD_RESP=$(curl -sf -X POST \
    -F "jarfile=@${fat_jar}" \
    "${flink_url}/jars/upload")
  JAR_ID=$(echo "$UPLOAD_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['filename'].split('/')[-1])")
  info "JAR uploaded: ${JAR_ID}"

  # Submit job
  RUN_RESP=$(curl -sf -X POST \
    -H "Content-Type: application/json" \
    -d "{\"entryClass\": \"com.lakehouse.KafkaToIcebergJob\", \"parallelism\": 1}" \
    "${flink_url}/jars/${JAR_ID}/run")
  JOB_ID=$(echo "$RUN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['jobid'])")
  info "Flink job submitted: ${JOB_ID}"

  # Wait for RUNNING
  elapsed=0
  while true; do
    STATE=$(curl -sf "${flink_url}/jobs/${JOB_ID}" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['state'])" 2>/dev/null || echo "UNKNOWN")
    if [ "$STATE" = "RUNNING" ]; then
      info "Flink job is RUNNING (${JOB_ID})"
      break
    fi
    if [ "$STATE" = "FAILED" ] || [ "$STATE" = "CANCELED" ]; then
      error "Flink job ${JOB_ID} entered state ${STATE}"
    fi
    if [ $elapsed -ge 120 ]; then
      error "Flink job did not reach RUNNING within 120s"
    fi
    sleep 5; elapsed=$((elapsed + 5))
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7 — Wait for Iceberg bronze tables to be seeded (first checkpoint)
# ═══════════════════════════════════════════════════════════════════════════
wait_for_bronze_data() {
  info "Waiting up to 120s for Iceberg bronze tables to be populated..."
  elapsed=0
  while true; do
    COUNT=$(docker exec trino trino \
      --server http://localhost:8080 \
      --execute "SELECT count(*) FROM iceberg.bronze.orders" \
      --output-format TSV 2>/dev/null | tail -1 | tr -d '[:space:]' || echo "0")
    if [ "${COUNT:-0}" -gt 0 ] 2>/dev/null; then
      info "Bronze tables have data (orders count: ${COUNT})."
      break
    fi
    if [ $elapsed -ge 180 ]; then
      warn "Bronze tables still empty after 180s — continuing anyway."
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 8 — Create Trino silver + gold views (tasks 6.4, 6.5)
# ═══════════════════════════════════════════════════════════════════════════
create_trino_views() {
  info "Creating Trino silver and gold views..."

  trino_exec() {
    docker exec trino trino \
      --server http://localhost:8080 \
      --execute "$1" 2>/dev/null
  }

  # Silver namespace
  trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.silver"
  trino_exec "CREATE SCHEMA IF NOT EXISTS iceberg.gold"

  # Silver: customers (latest per id, exclude deletes)
  trino_exec "
  CREATE OR REPLACE VIEW iceberg.silver.customers AS
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

  # Silver: products
  trino_exec "
  CREATE OR REPLACE VIEW iceberg.silver.products AS
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

  # Silver: orders
  trino_exec "
  CREATE OR REPLACE VIEW iceberg.silver.orders AS
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

  # Gold: order_summary (task 6.5)
  trino_exec "
  CREATE OR REPLACE VIEW iceberg.gold.order_summary AS
  SELECT
    c.city,
    SUM(o.total_amount)  AS total_revenue,
    COUNT(o.id)          AS order_count,
    AVG(o.total_amount)  AS avg_order_value
  FROM iceberg.silver.orders o
  JOIN iceberg.silver.customers c ON o.customer_id = c.id
  GROUP BY c.city
  "

  info "Trino views created."
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 9 — Create ClickHouse table and populate (tasks 7.2, 7.3)
# ═══════════════════════════════════════════════════════════════════════════
setup_clickhouse() {
  info "Creating ClickHouse order_agg table..."
  curl -sf http://localhost:8123/ \
    --data-urlencode "query=
    CREATE TABLE IF NOT EXISTS default.order_agg (
        city            String,
        total_revenue   Float64,
        order_count     UInt64,
        avg_order_value Float64
    ) ENGINE = MergeTree()
    ORDER BY city" > /dev/null

  info "Populating ClickHouse order_agg from Trino gold view..."
  # Use Trino to read the gold view and insert into ClickHouse
  docker exec trino trino \
    --server http://localhost:8080 \
    --execute "
    INSERT INTO clickhouse.default.order_agg
    SELECT
      city,
      CAST(total_revenue    AS DOUBLE),
      CAST(order_count      AS BIGINT),
      CAST(avg_order_value  AS DOUBLE)
    FROM iceberg.gold.order_summary
    " 2>/dev/null || warn "ClickHouse population via Trino failed — run manually after bronze tables fill"

  info "ClickHouse setup complete."
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 10 — Register Superset datasources via REST API (task 8.3)
# ═══════════════════════════════════════════════════════════════════════════
register_superset_datasources() {
  info "Registering Superset datasources..."

  SUPERSET_URL="http://localhost:8088"
  # Obtain access token
  TOKEN=$(curl -sf -X POST "${SUPERSET_URL}/api/v1/security/login" \
    -H "Content-Type: application/json" \
    -d '{"username":"admin","password":"admin","provider":"db","refresh":true}' \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

  if [ -z "$TOKEN" ]; then
    warn "Could not obtain Superset token — datasources not registered. Retry manually."
    return
  fi

  auth_curl() { curl -sf -H "Authorization: Bearer ${TOKEN}" "$@"; }

  register_db() {
    local name="$1"; local uri="$2"; local driver="$3"
    # Check if already exists
    EXISTING=$(auth_curl "${SUPERSET_URL}/api/v1/database/" \
      | python3 -c "import sys,json; dbs=json.load(sys.stdin).get('result',[]); \
        print(next((str(d['id']) for d in dbs if d['database_name']=='${name}'),''))" 2>/dev/null || echo "")
    if [ -n "$EXISTING" ]; then
      info "Superset DB '${name}' already registered (id=${EXISTING})."
      return
    fi
    HTTP=$(auth_curl -o /tmp/ss_resp.json -w "%{http_code}" \
      -X POST "${SUPERSET_URL}/api/v1/database/" \
      -H "Content-Type: application/json" \
      -d "{
        \"database_name\": \"${name}\",
        \"sqlalchemy_uri\": \"${uri}\",
        \"expose_in_sqllab\": true,
        \"allow_run_async\": false
      }")
    if [ "$HTTP" = "201" ]; then
      info "Superset DB '${name}' registered."
    else
      warn "Superset DB '${name}' registration returned HTTP ${HTTP}"
      cat /tmp/ss_resp.json || true
    fi
  }

  register_db "Trino - Lakehouse"      "trino://admin@trino:8080/iceberg"                  "trino"
  register_db "ClickHouse - Lakehouse" "clickhouse+http://default:@clickhouse:8123/default" "clickhouse"

  info "Superset datasource registration complete."
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
main() {
  info "=== Lakehouse POC Bootstrap ==="
  info "Project dir: ${PROJECT_DIR}"

  install_docker
  install_java_maven
  start_services
  register_connector
  FAT_JAR=$(build_flink_jar)
  submit_flink_job "$FAT_JAR"
  wait_for_bronze_data
  create_trino_views
  setup_clickhouse
  register_superset_datasources

  echo ""
  info "=== Bootstrap Complete ==="
  echo ""
  echo "  Flink UI:       http://localhost:8082"
  echo "  Trino:          http://localhost:8080"
  echo "  MinIO Console:  http://localhost:9001  (minioadmin / minioadmin123)"
  echo "  ClickHouse:     http://localhost:8123"
  echo "  Superset:       http://localhost:8088  (admin / admin)"
  echo ""
  echo "  Run validation: bash scripts/validate.sh"
}

main "$@"
