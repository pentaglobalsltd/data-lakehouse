#!/bin/bash
# Custom entrypoint for apache/hive:3.1.3 (metastore only).
# The JDBC jar is pre-placed in /opt/hive/lib/extra/ by the hive-lib-init
# container (alpine + wget) so this script never needs a download tool.
set -e

JDBC_DST="/opt/hive/lib/postgresql-jdbc.jar"

# ── 1. Verify JDBC driver is present (bind-mounted from host) ─────────────
if [ ! -f "$JDBC_DST" ]; then
    echo "[hive-metastore] ERROR: $JDBC_DST not found. Ensure postgresql-42.6.0.jar exists in hive-metastore/ on the host."
    exit 1
fi
echo "[hive-metastore] JDBC driver present at $JDBC_DST."

# ── 2. Wait for PostgreSQL TCP ────────────────────────────────────────────
echo "[hive-metastore] Waiting for PostgreSQL at postgres:5432..."
for i in $(seq 1 60); do
    if bash -c 'exec 3<>/dev/tcp/postgres/5432' 2>/dev/null; then
        echo "[hive-metastore] PostgreSQL is reachable."
        break
    fi
    echo "[hive-metastore] Still waiting ($i/60)..."
    sleep 3
done

# ── 3. Initialise metastore schema (idempotent) ───────────────────────────
echo "[hive-metastore] Checking metastore schema..."
if /opt/hive/bin/schematool -dbType postgres -validate > /dev/null 2>&1; then
    echo "[hive-metastore] Schema already initialised."
else
    echo "[hive-metastore] Initialising schema via schematool..."
    /opt/hive/bin/schematool -dbType postgres -initSchema
    echo "[hive-metastore] Schema initialised."
fi

# ── 4. Start HMS via the standard Hive entrypoint ────────────────────────
# IS_RESUME=true (set in docker-compose) tells it to skip its own schematool.
echo "[hive-metastore] Starting Hive Metastore thrift server on :9083..."
exec /entrypoint.sh
