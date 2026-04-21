#!/bin/bash
# Custom entrypoint for apache/hive:3.1.3 (metastore only).
# Ensures the PostgreSQL JDBC driver is present, waits for Postgres,
# initialises the metastore schema once, then starts HMS via the
# standard image entrypoint with IS_RESUME=true (skip its own schematool).
set -e

EXTRA_LIB="/opt/hive/lib/extra"
JDBC_JAR="/opt/hive/lib/postgresql-jdbc.jar"
JDBC_URL="https://jdbc.postgresql.org/download/postgresql-42.6.0.jar"

# ── 1. Obtain the PostgreSQL JDBC driver ──────────────────────────────────
if [ -f "${EXTRA_LIB}/postgresql-jdbc.jar" ]; then
    cp "${EXTRA_LIB}/postgresql-jdbc.jar" "$JDBC_JAR"
    echo "[hive-metastore] JDBC driver copied from pre-downloaded volume."
else
    echo "[hive-metastore] JDBC driver not pre-downloaded; fetching from internet..."
    # apache/hive:3.1.3 is Ubuntu-based but ships without curl or wget.
    # Install wget via apt if needed (fast, ~300 KB).
    if ! command -v wget &>/dev/null && ! command -v curl &>/dev/null; then
        echo "[hive-metastore] Installing wget..."
        apt-get update -qq 2>/dev/null && apt-get install -y -qq wget 2>/dev/null
    fi
    if command -v wget &>/dev/null; then
        wget -q -O "$JDBC_JAR" "$JDBC_URL"
    elif command -v curl &>/dev/null; then
        curl -fsSL -o "$JDBC_JAR" "$JDBC_URL"
    else
        echo "[hive-metastore] ERROR: no download tool available and jar not pre-downloaded."
        echo "  Run bootstrap.sh first, or manually place postgresql-jdbc.jar in ./hive-metastore/"
        exit 1
    fi
    echo "[hive-metastore] JDBC driver downloaded."
fi

# ── 2. Wait for PostgreSQL TCP ────────────────────────────────────────────
echo "[hive-metastore] Waiting for PostgreSQL at postgres:5432..."
for i in $(seq 1 60); do
    if bash -c 'exec 3<>/dev/tcp/postgres/5432' 2>/dev/null; then
        echo "[hive-metastore] PostgreSQL is reachable."
        break
    fi
    echo "[hive-metastore] Still waiting for PostgreSQL ($i/60)..."
    sleep 3
done

# ── 3. Initialise metastore schema (idempotent) ───────────────────────────
echo "[hive-metastore] Checking metastore schema..."
if /opt/hive/bin/schematool -dbType postgres -validate > /dev/null 2>&1; then
    echo "[hive-metastore] Schema already initialised and valid."
else
    echo "[hive-metastore] Running schematool -initSchema..."
    /opt/hive/bin/schematool -dbType postgres -initSchema
    echo "[hive-metastore] Schema initialised."
fi

# ── 4. Delegate to the standard Hive entrypoint ───────────────────────────
# IS_RESUME=true tells it to skip its own schematool run since we did it above.
export SERVICE_NAME=metastore
export IS_RESUME=true
echo "[hive-metastore] Starting HMS thrift server on :9083..."
exec /entrypoint.sh
