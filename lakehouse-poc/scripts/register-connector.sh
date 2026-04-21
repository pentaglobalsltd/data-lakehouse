#!/usr/bin/env bash
# register-connector.sh
# Polls Kafka Connect until ready, then registers the Debezium connector.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONNECTOR_JSON="${SCRIPT_DIR}/../kafka-connect/debezium-connector.json"
CONNECT_URL="${CONNECT_URL:-http://localhost:8091}"
# Optional basic auth for nginx-proxied endpoint (set via env from bootstrap.sh)
CONNECT_BASIC_AUTH="${CONNECT_BASIC_AUTH:-}"
CURL_AUTH_ARGS=""
[ -n "$CONNECT_BASIC_AUTH" ] && CURL_AUTH_ARGS="-u ${CONNECT_BASIC_AUTH}"
CONNECTOR_NAME="pg-lakehouse-connector"
MAX_WAIT=120   # seconds

# ─── Wait for Kafka Connect REST API ──────────────────────────────────────
echo "[register-connector] Waiting for Kafka Connect at ${CONNECT_URL} ..."
elapsed=0
until curl -sf $CURL_AUTH_ARGS "${CONNECT_URL}/connectors" > /dev/null 2>&1; do
  if [ $elapsed -ge $MAX_WAIT ]; then
    echo "[register-connector] ERROR: Kafka Connect did not become available within ${MAX_WAIT}s"
    exit 1
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
echo "[register-connector] Kafka Connect is ready."

# ─── Check if connector already exists ────────────────────────────────────
if curl -sf $CURL_AUTH_ARGS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}" > /dev/null 2>&1; then
  echo "[register-connector] Connector '${CONNECTOR_NAME}' already exists — skipping."
  exit 0
fi

# ─── Register the connector ───────────────────────────────────────────────
echo "[register-connector] Registering connector from ${CONNECTOR_JSON} ..."
HTTP_CODE=$(curl -s -o /tmp/connect_response.json -w "%{http_code}" \
  $CURL_AUTH_ARGS \
  -X POST "${CONNECT_URL}/connectors" \
  -H "Content-Type: application/json" \
  -d @"${CONNECTOR_JSON}")

if [ "$HTTP_CODE" -ne 201 ] && [ "$HTTP_CODE" -ne 200 ]; then
  echo "[register-connector] ERROR: HTTP ${HTTP_CODE}"
  cat /tmp/connect_response.json
  exit 1
fi
echo "[register-connector] Connector registered (HTTP ${HTTP_CODE})."

# ─── Wait for RUNNING state ───────────────────────────────────────────────
echo "[register-connector] Waiting for connector to reach RUNNING state ..."
elapsed=0
while true; do
  STATE=$(curl -sf $CURL_AUTH_ARGS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
  if [ "$STATE" = "RUNNING" ]; then
    echo "[register-connector] Connector is RUNNING."
    break
  fi
  if [ $elapsed -ge 60 ]; then
    echo "[register-connector] ERROR: Connector did not reach RUNNING within 60s. State: ${STATE}"
    curl -sf $CURL_AUTH_ARGS "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" || true
    exit 1
  fi
  sleep 3
  elapsed=$((elapsed + 3))
done
