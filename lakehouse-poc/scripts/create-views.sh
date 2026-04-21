#!/usr/bin/env bash
# create-views.sh — Run dbt to create/refresh silver and gold Trino views.
# Views are now backed by Hive Metastore and survive Trino restarts.
#
# Called by bootstrap.sh (via the dbt-init container on compose up)
# and by the Airflow DAG on schedule.
set -euo pipefail

DBT_DIR="${DBT_DIR:-/opt/dbt}"
TRINO_HOST="${TRINO_HOST:-trino}"
TRINO_PORT="${TRINO_PORT:-8080}"

echo "[create-views] Running dbt to create/refresh silver + gold views..."
echo "[create-views] Trino: ${TRINO_HOST}:${TRINO_PORT}"

cd "$DBT_DIR"

# Retry loop: bronze tables may not exist yet if Flink hasn't started
ATTEMPTS=0
MAX_ATTEMPTS=20
until dbt run --profiles-dir "${DBT_DIR}" --target dev; do
  ATTEMPTS=$((ATTEMPTS + 1))
  if [ "$ATTEMPTS" -ge "$MAX_ATTEMPTS" ]; then
    echo "[create-views] ERROR: dbt run failed after ${MAX_ATTEMPTS} attempts."
    exit 1
  fi
  echo "[create-views] dbt run failed (attempt ${ATTEMPTS}/${MAX_ATTEMPTS}). Retrying in 30s..."
  sleep 30
done

echo "[create-views] dbt run complete — silver and gold views are up to date."
