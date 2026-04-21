"""
Lakehouse pipeline DAG — runs every 30 minutes.

Tasks:
  1. dbt_run          : refresh silver + gold Trino views via dbt
  2. sync_clickhouse  : truncate + INSERT order_agg from gold view (idempotent)
  3. monitoring_check : WAL lag, connector state, Flink job state
"""
from __future__ import annotations

import logging
import os
import subprocess
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.bash import BashOperator
from airflow.operators.python import PythonOperator

log = logging.getLogger(__name__)

default_args = {
    "owner": "lakehouse",
    "retries": 1,
    "retry_delay": timedelta(minutes=2),
    "on_failure_callback": lambda ctx: log.error(
        "Task %s failed in DAG run %s: %s",
        ctx["task_instance"].task_id,
        ctx["run_id"],
        ctx.get("exception"),
    ),
}

# ─── Task implementations ──────────────────────────────────────────────────

def _sync_clickhouse(**_):
    """Truncate + repopulate ClickHouse order_agg from the gold Trino view."""
    import requests

    ch_url = f"http://{os.environ.get('CLICKHOUSE_HOST', 'clickhouse')}:8123/"
    ch_user = "default"
    ch_pass = os.environ.get("CLICKHOUSE_PASSWORD", "")

    def ch(sql: str) -> str:
        r = requests.post(ch_url, data=sql, auth=(ch_user, ch_pass), timeout=60)
        r.raise_for_status()
        return r.text.strip()

    ch(
        "CREATE TABLE IF NOT EXISTS default.order_agg ("
        "  city String, total_revenue Float64,"
        "  order_count UInt64, avg_order_value Float64"
        ") ENGINE = MergeTree() ORDER BY city"
    )
    ch("TRUNCATE TABLE default.order_agg")

    # Push data via Trino INSERT SELECT using the trino provider
    from airflow.providers.trino.hooks.trino import TrinoHook

    hook = TrinoHook(trino_conn_id="trino_default")
    hook.run(
        """
        INSERT INTO clickhouse.default.order_agg
        SELECT
          city,
          CAST(total_revenue   AS DOUBLE),
          CAST(order_count     AS BIGINT),
          CAST(avg_order_value AS DOUBLE)
        FROM lakehouse.gold.order_summary
        """
    )
    log.info("ClickHouse order_agg synced successfully.")


def _monitoring_check(**_):
    """Run the replication lag check script and raise on failure."""
    result = subprocess.run(
        ["bash", "/opt/scripts/check-replication-lag.sh"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    log.info(result.stdout)
    if result.returncode != 0:
        log.error(result.stderr)
        raise RuntimeError(
            f"Monitoring check failed (exit {result.returncode}):\n{result.stdout}\n{result.stderr}"
        )


# ─── DAG definition ───────────────────────────────────────────────────────

with DAG(
    dag_id="lakehouse_pipeline",
    description="dbt refresh + ClickHouse sync + replication monitoring",
    schedule="*/30 * * * *",
    start_date=datetime(2026, 4, 21),
    catchup=False,
    default_args=default_args,
    tags=["lakehouse"],
) as dag:

    dbt_run = BashOperator(
        task_id="dbt_run",
        bash_command=(
            "cd /opt/dbt && "
            "dbt run --profiles-dir /opt/dbt --target dev"
        ),
        env={
            **os.environ,
            "TRINO_HOST": os.environ.get("TRINO_HOST", "trino"),
            "TRINO_PORT": os.environ.get("TRINO_PORT", "8080"),
        },
    )

    sync_clickhouse = PythonOperator(
        task_id="sync_clickhouse",
        python_callable=_sync_clickhouse,
    )

    monitoring_check = PythonOperator(
        task_id="monitoring_check",
        python_callable=_monitoring_check,
        # Don't block the pipeline if monitoring fails
        trigger_rule="all_done",
    )

    dbt_run >> sync_clickhouse >> monitoring_check
