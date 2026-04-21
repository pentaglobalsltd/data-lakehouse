#!/bin/bash
# Custom entrypoint for apache/hive:3.1.3 running as HMS only.
# Copies the Postgres JDBC driver (mounted from host via bootstrap.sh download),
# initializes the metastore schema in Postgres, then delegates to the
# standard Hive entrypoint.
set -e

# The host dir ./hive-metastore/ is mounted at /opt/hive/lib/extra/
# bootstrap.sh downloads postgresql-jdbc.jar there before compose up.
EXTRA_LIB="/opt/hive/lib/extra"
JDBC_JAR="/opt/hive/lib/postgresql-jdbc.jar"
JDBC_URL="https://jdbc.postgresql.org/download/postgresql-42.6.0.jar"

if [ ! -f "$JDBC_JAR" ]; then
  if [ -f "${EXTRA_LIB}/postgresql-jdbc.jar" ]; then
    cp "${EXTRA_LIB}/postgresql-jdbc.jar" "$JDBC_JAR"
    echo "[hive-metastore] Copied JDBC driver from mounted volume."
  else
    echo "[hive-metastore] Downloading PostgreSQL JDBC driver (not pre-downloaded)..."
    curl -fsSL -o "$JDBC_JAR" "$JDBC_URL"
    echo "[hive-metastore] JDBC driver downloaded."
  fi
fi

# Wait for Postgres TCP (port 5432)
echo "[hive-metastore] Waiting for PostgreSQL at postgres:5432 ..."
for i in $(seq 1 60); do
  if bash -c 'exec 3<>/dev/tcp/postgres/5432' 2>/dev/null; then
    echo "[hive-metastore] PostgreSQL is reachable."
    break
  fi
  echo "[hive-metastore] Waiting for PostgreSQL ($i/60)..."
  sleep 3
done

# Initialize or validate Hive Metastore schema in Postgres
echo "[hive-metastore] Checking metastore schema..."
if /opt/hive/bin/schematool -dbType postgres -validate > /dev/null 2>&1; then
  echo "[hive-metastore] Metastore schema already initialized and valid."
else
  echo "[hive-metastore] Initializing metastore schema..."
  /opt/hive/bin/schematool -dbType postgres -initSchema
  echo "[hive-metastore] Schema initialized."
fi

# Start the metastore service via the standard Hive entrypoint
export SERVICE_NAME=metastore
echo "[hive-metastore] Starting Hive Metastore thrift server on :9083 ..."
exec /entrypoint.sh
