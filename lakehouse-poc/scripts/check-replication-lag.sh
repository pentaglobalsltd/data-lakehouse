#!/usr/bin/env bash
# check-replication-lag.sh
# Checks PostgreSQL WAL replication lag, Kafka Connect connector state,
# and Flink job state. Exits non-zero if any check fails.
# If SLACK_WEBHOOK_URL is set in environment, posts a message on failure.
#
# Usage (host):       bash scripts/check-replication-lag.sh
# Usage (Airflow):    called from lakehouse_pipeline DAG monitoring_check task

set -uo pipefail

# ─── Configuration ────────────────────────────────────────────────────────
CONNECT_URL="${CONNECT_URL:-http://localhost:8091}"
FLINK_URL="${FLINK_URL:-http://localhost:8090}"
WAL_LAG_LIMIT_MB="${WAL_LAG_LIMIT_MB:-500}"
CONNECTOR_NAME="pg-lakehouse-connector"

# Credentials for nginx-proxied endpoints (set in .env)
NGINX_USERNAME="${NGINX_USERNAME:-admin}"
NGINX_PASSWORD="${NGINX_PASSWORD:-nginxpass123}"

GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; NC='\033[0m'
FAILED=0

ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
fail() { echo -e "${RED}[FAIL]${NC} $*"; FAILED=$((FAILED + 1)); }

echo ""
echo "════════════════════════════════════════════════════════"
echo "  Lakehouse Replication & Service Health Check"
echo "════════════════════════════════════════════════════════"

# ─── 1. PostgreSQL replication slot WAL lag ───────────────────────────────
echo ""
echo "── PostgreSQL Replication Slots ──"
WAL_INFO=$(docker exec postgres psql -U lakeuser -d lakedb -t -A -c \
  "SELECT slot_name || '|' || coalesce(pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)), 'N/A') || '|' || coalesce(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn) / 1048576, 0) FROM pg_replication_slots;" \
  2>/dev/null || echo "ERROR|N/A|0")

while IFS='|' read -r slot pretty_size size_mb; do
  [ -z "$slot" ] && continue
  if [ "${size_mb:-0}" -gt "$WAL_LAG_LIMIT_MB" ] 2>/dev/null; then
    fail "Slot '${slot}': WAL lag ${pretty_size} exceeds ${WAL_LAG_LIMIT_MB}MB threshold"
  else
    ok "Slot '${slot}': WAL lag ${pretty_size}"
  fi
done <<< "$WAL_INFO"

# ─── 2. Kafka Connect connector state ────────────────────────────────────
echo ""
echo "── Kafka Connect Connector State ──"
CONN_STATUS=$(curl -sf -u "${NGINX_USERNAME}:${NGINX_PASSWORD}" \
  "${CONNECT_URL}/connectors/${CONNECTOR_NAME}/status" 2>/dev/null || echo "")

if [ -z "$CONN_STATUS" ]; then
  fail "Cannot reach Kafka Connect at ${CONNECT_URL}"
else
  CONN_STATE=$(echo "$CONN_STATUS" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(d['connector']['state'])" 2>/dev/null || echo "UNKNOWN")
  TASK_STATES=$(echo "$CONN_STATUS" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); print(','.join(t['state'] for t in d.get('tasks',[])))" 2>/dev/null || echo "")

  if [ "$CONN_STATE" = "RUNNING" ]; then
    ok "Connector '${CONNECTOR_NAME}': ${CONN_STATE} (tasks: ${TASK_STATES})"
  else
    fail "Connector '${CONNECTOR_NAME}': ${CONN_STATE} (tasks: ${TASK_STATES})"
  fi
fi

# ─── 3. Flink job state ───────────────────────────────────────────────────
echo ""
echo "── Flink Job State ──"
FLINK_JOBS=$(curl -sf -u "${NGINX_USERNAME}:${NGINX_PASSWORD}" \
  "${FLINK_URL}/jobs" 2>/dev/null || echo "")

if [ -z "$FLINK_JOBS" ]; then
  fail "Cannot reach Flink JobManager at ${FLINK_URL}"
else
  RUNNING_COUNT=$(echo "$FLINK_JOBS" | python3 -c \
    "import sys,json; jobs=json.load(sys.stdin)['jobs']; print(sum(1 for j in jobs if j['status']=='RUNNING'))" 2>/dev/null || echo "0")
  ALL_STATES=$(echo "$FLINK_JOBS" | python3 -c \
    "import sys,json; jobs=json.load(sys.stdin)['jobs']; print(', '.join(j['status'] for j in jobs) or 'none')" 2>/dev/null || echo "unknown")

  if [ "${RUNNING_COUNT:-0}" -ge 1 ]; then
    ok "Flink: ${RUNNING_COUNT} job(s) RUNNING (all: ${ALL_STATES})"
  else
    fail "Flink: no RUNNING jobs (all: ${ALL_STATES})"
  fi
fi

# ─── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════"
if [ "$FAILED" -eq 0 ]; then
  echo -e "${GREEN}  All checks passed.${NC}"
else
  echo -e "${RED}  ${FAILED} check(s) FAILED.${NC}"

  # Optional Slack alert
  if [ -n "${SLACK_WEBHOOK_URL:-}" ]; then
    HOSTNAME=$(hostname)
    PAYLOAD=$(python3 -c "
import json, sys
msg = sys.argv[1]
print(json.dumps({'text': f':red_circle: *Lakehouse monitoring alert* on {msg}'}))
" "${HOSTNAME}: ${FAILED} check(s) failed — $(date -u)")
    curl -sf -X POST -H 'Content-type: application/json' \
      --data "$PAYLOAD" "$SLACK_WEBHOOK_URL" > /dev/null || true
  fi
fi
echo "════════════════════════════════════════════════════════"
echo ""

exit "$FAILED"
