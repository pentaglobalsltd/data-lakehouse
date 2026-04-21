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
# Load .env (optional — stack uses defaults if absent)
# ═══════════════════════════════════════════════════════════════════════════
load_env() {
  if [ -f "${PROJECT_DIR}/.env" ]; then
    info "Loading credentials from .env ..."
    set -a; source "${PROJECT_DIR}/.env"; set +a
  else
    warn ".env not found — using defaults. Copy .env.example → .env and set secure values."
  fi
  # Expose variables used by this script (fall back to defaults)
  MINIO_ACCESS_KEY="${MINIO_ACCESS_KEY:-minioadmin}"
  MINIO_SECRET_KEY="${MINIO_SECRET_KEY:-minioadmin123}"
  POSTGRES_USER="${POSTGRES_USER:-lakeuser}"
  POSTGRES_PASSWORD="${POSTGRES_PASSWORD:-lakepass}"
  TRINO_ADMIN_PASSWORD="${TRINO_ADMIN_PASSWORD:-trinopass123}"
  NGINX_USERNAME="${NGINX_USERNAME:-admin}"
  NGINX_PASSWORD="${NGINX_PASSWORD:-nginxpass123}"
  CLICKHOUSE_PASSWORD="${CLICKHOUSE_PASSWORD:-clickpass123}"
  AIRFLOW_ADMIN_PASSWORD="${AIRFLOW_ADMIN_PASSWORD:-airflowpass123}"
  export MINIO_ACCESS_KEY MINIO_SECRET_KEY POSTGRES_USER POSTGRES_PASSWORD \
         TRINO_ADMIN_PASSWORD NGINX_USERNAME NGINX_PASSWORD \
         CLICKHOUSE_PASSWORD AIRFLOW_ADMIN_PASSWORD
}

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
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 2 — Install Java 11 + Maven
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
    info "Maven already installed. Skipping."
  else
    info "Installing Maven..."
    sudo apt-get install -y -qq maven
  fi
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 3 — Generate auth credentials (htpasswd, Trino keystore + password.db)
# ═══════════════════════════════════════════════════════════════════════════
generate_auth_artifacts() {
  info "Generating auth artifacts..."
  cd "$PROJECT_DIR"

  # nginx .htpasswd (Apache MD5 — compatible with nginx auth_basic)
  sudo apt-get install -y -qq apache2-utils 2>/dev/null || true
  if command -v htpasswd &>/dev/null; then
    htpasswd -cbm nginx/.htpasswd "$NGINX_USERNAME" "$NGINX_PASSWORD"
  else
    # Fallback: openssl APR1-MD5
    HASH=$(openssl passwd -apr1 "$NGINX_PASSWORD")
    echo "${NGINX_USERNAME}:${HASH}" > nginx/.htpasswd
  fi
  info "nginx/.htpasswd written."

  # Trino self-signed TLS keystore (JKS) — needed for HTTPS password auth
  if [ ! -f trino/keystore.jks ]; then
    info "Generating self-signed Trino TLS keystore..."
    keytool -genkeypair \
      -alias trino \
      -keyalg RSA \
      -keysize 2048 \
      -validity 3650 \
      -keystore trino/keystore.jks \
      -storepass trinokeystorepass \
      -keypass trinokeystorepass \
      -dname "CN=trino, OU=lakehouse, O=poc, L=local, S=local, C=US" \
      2>/dev/null
    info "Trino keystore generated."
  else
    info "Trino keystore already exists."
  fi

  # Trino password.db (bcrypt — required by file password authenticator)
  info "Generating trino/password.db ..."
  python3 - <<PYEOF
import sys
try:
    import bcrypt
except ImportError:
    import subprocess
    subprocess.run([sys.executable, '-m', 'pip', 'install', 'bcrypt', '-q'], check=True)
    import bcrypt
import os
pw = os.environ.get('TRINO_ADMIN_PASSWORD', 'trinopass123').encode()
h = bcrypt.hashpw(pw, bcrypt.gensalt()).decode()
with open('trino/password.db', 'w') as f:
    f.write(f"admin:{h}\n")
print("trino/password.db written.")
PYEOF

  # Download Hive Metastore PostgreSQL JDBC driver
  if [ ! -f hive-metastore/postgresql-jdbc.jar ]; then
    info "Downloading PostgreSQL JDBC driver for Hive Metastore..."
    curl -fsSL -o hive-metastore/postgresql-jdbc.jar \
      https://jdbc.postgresql.org/download/postgresql-42.6.0.jar
  fi

  cd - > /dev/null
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
# STEP 4 — Start all services
# ═══════════════════════════════════════════════════════════════════════════
start_services() {
  info "Starting all services with Docker Compose..."
  cd "$PROJECT_DIR"

  # Ensure extra Postgres databases exist even if container was already initialized
  # (02_extra_dbs.sql handles fresh installs; this handles existing volumes)
  ensure_extra_dbs() {
    for dbname in metastore airflow; do
      docker exec postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_USER" -tc \
        "SELECT 'CREATE DATABASE ${dbname}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${dbname}')" \
        | docker exec -i postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_USER" 2>/dev/null || true
    done
  }

  sudo docker compose up -d 2>&1 || docker compose up -d 2>&1

  wait_healthy postgres     180
  # Create metastore + airflow databases (idempotent)
  ensure_extra_dbs
  wait_healthy zookeeper    120
  wait_healthy kafka        180
  wait_healthy minio        120
  info "Waiting for minio-init to complete..."
  timeout 120 bash -c '
    until [ "$(docker inspect --format="{{.State.Status}}" minio-init 2>/dev/null)" = "exited" ]; do
      sleep 3
    done
    EC=$(docker inspect --format="{{.State.ExitCode}}" minio-init)
    [ "$EC" = "0" ] && echo "minio-init: done" || (echo "minio-init failed (exit $EC)" && exit 1)
  ' || error "minio-init did not complete successfully"
  wait_healthy iceberg-rest  120
  wait_healthy hive-metastore 300
  wait_healthy kafka-connect 300
  wait_healthy flink-jobmanager 120
  wait_healthy nginx         60
  wait_healthy trino         180
  wait_healthy clickhouse    120
  wait_healthy superset      240
  info "Waiting for airflow-init to complete..."
  timeout 300 bash -c '
    until [ "$(docker inspect --format="{{.State.Status}}" airflow-init 2>/dev/null)" = "exited" ]; do
      sleep 5
    done
    EC=$(docker inspect --format="{{.State.ExitCode}}" airflow-init)
    [ "$EC" = "0" ] && echo "airflow-init: done" || (echo "airflow-init failed (exit $EC)" && exit 1)
  ' || warn "airflow-init did not complete — check logs with: docker logs airflow-init"
  wait_healthy airflow-webserver 120
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 5 — Register Debezium connector (via nginx proxy)
# ═══════════════════════════════════════════════════════════════════════════
register_connector() {
  info "Registering Debezium connector..."
  CONNECT_URL="http://localhost:8091" \
  CONNECT_BASIC_AUTH="${NGINX_USERNAME}:${NGINX_PASSWORD}" \
    bash "${SCRIPT_DIR}/register-connector.sh"
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 6 — Build Flink fat JAR
# ═══════════════════════════════════════════════════════════════════════════
build_flink_jar() {
  info "Building Flink fat JAR..."
  cd "$PROJECT_DIR"
  mvn package -f flink-jobs/pom.xml -DskipTests -q
  BUILT_FAT_JAR=$(find flink-jobs/target -name "*-fat.jar" | head -1)
  if [ -z "$BUILT_FAT_JAR" ]; then
    error "Fat JAR not found after Maven build"
  fi
  info "Built: ${BUILT_FAT_JAR}"
  cd - > /dev/null
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 7 — Submit Flink JAR (with HA skip logic)
# Checks GET /jobs before submitting:
#   RUNNING → skip
#   FAILED  → cancel, find latest savepoint, resubmit from savepoint if found
#   absent  → fresh submit
# ═══════════════════════════════════════════════════════════════════════════
submit_flink_job() {
  local fat_jar="${1:-}"
  local flink_url="http://localhost:8090"
  local auth_header="Authorization: Basic $(echo -n "${NGINX_USERNAME}:${NGINX_PASSWORD}" | base64)"

  # ── Check current job state ──────────────────────────────────────────────
  JOBS_JSON=$(curl -sf -H "$auth_header" "${flink_url}/jobs" 2>/dev/null || echo '{"jobs":[]}')
  RUNNING_ID=$(echo "$JOBS_JSON" | python3 -c \
    "import sys,json; jobs=json.load(sys.stdin)['jobs']; print(next((j['id'] for j in jobs if j['status']=='RUNNING'),''))" 2>/dev/null || echo "")
  FAILED_ID=$(echo "$JOBS_JSON" | python3 -c \
    "import sys,json; jobs=json.load(sys.stdin)['jobs']; print(next((j['id'] for j in jobs if j['status']=='FAILED'),''))" 2>/dev/null || echo "")

  if [ -n "$RUNNING_ID" ]; then
    info "Flink job already RUNNING (${RUNNING_ID}). Skipping submission."
    return 0
  fi

  SAVEPOINT_PATH=""
  if [ -n "$FAILED_ID" ]; then
    warn "Found FAILED Flink job (${FAILED_ID}). Cancelling..."
    curl -sf -H "$auth_header" -H "Content-Type: application/json" \
      -X PATCH "${flink_url}/jobs/${FAILED_ID}" \
      -d '{"targetState":"CANCELED"}' > /dev/null 2>&1 || true
    sleep 5

    # Look for a savepoint in MinIO
    info "Checking for existing savepoints in MinIO..."
    SAVEPOINT_PATH=$(docker run --rm --network lakehouse minio/mc:latest sh -c \
      "mc alias set m http://minio:9000 ${MINIO_ACCESS_KEY} ${MINIO_SECRET_KEY} -q 2>/dev/null && \
       mc ls m/lakehouse/flink-savepoints/ 2>/dev/null | awk '{print \$NF}' | sort | tail -1" \
      2>/dev/null || echo "")
    if [ -n "$SAVEPOINT_PATH" ]; then
      SAVEPOINT_PATH="s3://lakehouse/flink-savepoints/${SAVEPOINT_PATH}"
      info "Found savepoint: ${SAVEPOINT_PATH}"
    else
      warn "No savepoint found — submitting fresh."
    fi
  fi

  if [ -z "$fat_jar" ]; then
    fat_jar=$(find "${PROJECT_DIR}/flink-jobs/target" -name "*-fat.jar" | head -1)
    [ -z "$fat_jar" ] && error "Fat JAR not found — run build_flink_jar first"
  fi

  info "Submitting Flink job from ${fat_jar} ..."
  UPLOAD_RESP=$(curl -sf -H "$auth_header" -X POST \
    -F "jarfile=@${fat_jar}" \
    "${flink_url}/jars/upload")
  JAR_ID=$(echo "$UPLOAD_RESP" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['filename'].split('/')[-1])")
  info "JAR uploaded: ${JAR_ID}"

  # Build run body (optionally include savepoint)
  if [ -n "$SAVEPOINT_PATH" ]; then
    RUN_BODY="{\"entryClass\":\"com.lakehouse.KafkaToIcebergJob\",\"parallelism\":1,\"savepointPath\":\"${SAVEPOINT_PATH}\",\"allowNonRestoredState\":true}"
  else
    RUN_BODY='{"entryClass":"com.lakehouse.KafkaToIcebergJob","parallelism":1}'
  fi

  RUN_RESP=$(curl -sf -H "$auth_header" -H "Content-Type: application/json" \
    -X POST -d "$RUN_BODY" "${flink_url}/jars/${JAR_ID}/run")
  JOB_ID=$(echo "$RUN_RESP" | python3 -c \
    "import sys,json; print(json.load(sys.stdin)['jobid'])")
  info "Flink job submitted: ${JOB_ID}"

  elapsed=0
  while true; do
    STATE=$(curl -sf -H "$auth_header" "${flink_url}/jobs/${JOB_ID}" \
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
# STEP 8 — Wait for Iceberg bronze tables to be seeded
# ═══════════════════════════════════════════════════════════════════════════
wait_for_bronze_data() {
  info "Waiting up to 180s for Iceberg bronze tables to be populated..."
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
      warn "Bronze tables still empty after 180s — continuing anyway (dbt-init will retry)."
      break
    fi
    sleep 10; elapsed=$((elapsed + 10))
  done
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 9 — Create ClickHouse table
# ClickHouse population is now handled by the Airflow DAG on schedule.
# ═══════════════════════════════════════════════════════════════════════════
setup_clickhouse() {
  info "Creating ClickHouse order_agg table schema..."
  curl -sf "http://localhost:8123/" \
    -u "default:${CLICKHOUSE_PASSWORD}" \
    -d "
    CREATE TABLE IF NOT EXISTS default.order_agg (
        city            String,
        total_revenue   Float64,
        order_count     UInt64,
        avg_order_value Float64
    ) ENGINE = MergeTree()
    ORDER BY city" > /dev/null
  info "ClickHouse table ready. Initial population will run via Airflow DAG (lakehouse_pipeline)."
  info "To trigger now: open Airflow at http://localhost:8089 and run the DAG manually."
}

# ═══════════════════════════════════════════════════════════════════════════
# STEP 10 — Register Superset datasources
# ═══════════════════════════════════════════════════════════════════════════
register_superset_datasources() {
  info "Registering Superset datasources..."
  SUPERSET_URL="http://localhost:8088"
  TOKEN=$(curl -sf -X POST "${SUPERSET_URL}/api/v1/security/login" \
    -H "Content-Type: application/json" \
    -d "{\"username\":\"admin\",\"password\":\"${SUPERSET_ADMIN_PASSWORD:-admin}\",\"provider\":\"db\",\"refresh\":true}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])" 2>/dev/null || echo "")

  if [ -z "$TOKEN" ]; then
    warn "Could not obtain Superset token — datasources not registered. Retry manually."
    return
  fi

  auth_curl() { curl -sf -H "Authorization: Bearer ${TOKEN}" "$@"; }

  register_db() {
    local name="$1"; local uri="$2"
    EXISTING=$(auth_curl "${SUPERSET_URL}/api/v1/database/" \
      | python3 -c "import sys,json; dbs=json.load(sys.stdin).get('result',[]); \
        print(next((str(d['id']) for d in dbs if d['database_name']=='${name}'),''))" 2>/dev/null || echo "")
    if [ -n "$EXISTING" ]; then
      info "Superset DB '${name}' already registered."; return
    fi
    HTTP=$(auth_curl -o /tmp/ss_resp.json -w "%{http_code}" \
      -X POST "${SUPERSET_URL}/api/v1/database/" \
      -H "Content-Type: application/json" \
      -d "{\"database_name\":\"${name}\",\"sqlalchemy_uri\":\"${uri}\",\"expose_in_sqllab\":true,\"allow_run_async\":false}")
    [ "$HTTP" = "201" ] && info "Superset DB '${name}' registered." || \
      warn "Superset DB '${name}' HTTP ${HTTP}"
  }

  register_db "Trino - Lakehouse"      "trino://admin@trino:8080/iceberg"
  register_db "ClickHouse - Lakehouse" "clickhouse+http://default:${CLICKHOUSE_PASSWORD}@clickhouse:8123/default"
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════════════════════════
main() {
  info "=== Lakehouse POC Bootstrap ==="
  info "Project dir: ${PROJECT_DIR}"

  load_env
  install_docker
  install_java_maven
  generate_auth_artifacts
  start_services
  register_connector
  build_flink_jar
  submit_flink_job "$BUILT_FAT_JAR"
  wait_for_bronze_data
  setup_clickhouse
  register_superset_datasources

  echo ""
  info "=== Bootstrap Complete ==="
  echo ""
  echo "  Flink UI (auth):      http://localhost:8090   (${NGINX_USERNAME} / <NGINX_PASSWORD>)"
  echo "  Kafka Connect (auth): http://localhost:8091   (${NGINX_USERNAME} / <NGINX_PASSWORD>)"
  echo "  Trino (HTTP):         http://localhost:8080   (internal, no auth)"
  echo "  Trino (HTTPS+auth):   https://localhost:8443  (admin / <TRINO_ADMIN_PASSWORD>)"
  echo "  MinIO Console:        http://localhost:9001   (${MINIO_ACCESS_KEY} / <MINIO_SECRET_KEY>)"
  echo "  ClickHouse:           http://localhost:8123   (default / <CLICKHOUSE_PASSWORD>)"
  echo "  Airflow:              http://localhost:8089   (admin / <AIRFLOW_ADMIN_PASSWORD>)"
  echo "  Superset:             http://localhost:8088   (admin / <SUPERSET_ADMIN_PASSWORD>)"
  echo ""
  echo "  Monitoring:   bash scripts/check-replication-lag.sh"
  echo "  Validation:   bash scripts/validate.sh"
}

main "$@"
