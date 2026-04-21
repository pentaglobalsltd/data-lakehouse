# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

A data lakehouse POC using medallion architecture (bronze → silver → gold) with open-source tools on a single VM. Data flows from PostgreSQL via CDC (Debezium) through Kafka into Apache Iceberg (bronze), then exposed as persistent Trino views (silver/gold) backed by Hive Metastore, synced to ClickHouse for OLAP via Airflow.

## Common Commands

### Start / Stop the Stack

```bash
cd lakehouse-poc
docker compose up -d       # start all services (~18)
docker compose down -v     # tear down and wipe all volumes
```

### Full Bootstrap (first-time setup, ~12–15 min)

```bash
cd lakehouse-poc
cp .env.example .env       # fill in secure credentials
bash scripts/bootstrap.sh
```

Bootstrap generates auth artifacts (nginx .htpasswd, Trino keystore + password.db), starts all services, submits the Flink job, and registers datasources. ClickHouse population is now scheduled via Airflow every 30 minutes.

### Build Flink Job

```bash
mvn package -f lakehouse-poc/flink-jobs/pom.xml -DskipTests -q
# Output: lakehouse-poc/flink-jobs/target/*-fat.jar
```

### Create / Recreate Trino Views (via dbt)

```bash
cd lakehouse-poc
bash scripts/create-views.sh
# Runs dbt inside the dbt-init container. Views are persisted in Hive Metastore
# and survive Trino restarts without rerunning this script.
```

### Run Validation Tests

```bash
cd lakehouse-poc
bash scripts/validate.sh
# Runs INSERT/UPDATE/DELETE against PostgreSQL, waits 90s per test for Flink checkpoints
```

### Replication & Service Health Check

```bash
cd lakehouse-poc
bash scripts/check-replication-lag.sh
# Checks WAL lag, connector state, Flink job state. Exits non-zero on failure.
```

### Query Each Layer

```bash
# Bronze (raw Iceberg tables) — internal HTTP, no auth
docker exec trino trino --server http://localhost:8080 --execute "SELECT * FROM iceberg.bronze.orders LIMIT 10"

# Silver (deduplicated dbt views, HMS-backed)
docker exec trino trino --server http://localhost:8080 --execute "SELECT * FROM lakehouse.silver.orders LIMIT 10"

# Gold (aggregated dbt view)
docker exec trino trino --server http://localhost:8080 --execute "SELECT * FROM lakehouse.gold.order_summary"

# ClickHouse OLAP table (password from .env)
curl -u "default:${CLICKHOUSE_PASSWORD}" http://localhost:8123/ -d "SELECT * FROM default.order_agg"

# PostgreSQL source
docker exec postgres psql -U lakeuser -d lakedb -c "SELECT * FROM orders LIMIT 5"
```

### Register Debezium Connector

```bash
cd lakehouse-poc
CONNECT_BASIC_AUTH="admin:<NGINX_PASSWORD>" bash scripts/register-connector.sh
```

## Architecture

### Data Flow

```
PostgreSQL 16 (lakedb)
  → Debezium 2.5 (Kafka Connect, proxied via nginx :8091)   # CDC
  → Kafka 7.6.0 (topics: cdc.public.{customers,products,orders})
  → Flink 1.18.1 (KafkaToIcebergJob.java)                   # JSON → Iceberg upsert
  → Iceberg 1.5.2 (REST catalog, bronze.*)                  # MinIO s3://lakehouse/
  → Hive Metastore 3.1.3 (thrift :9083)                     # stores silver/gold view DDL
  → Trino 438 (lakehouse.silver.*, gold.*)                  # dbt-managed persistent views
  → Airflow 2.8.1 (lakehouse_pipeline DAG, every 30 min)    # dbt run + ClickHouse sync
  → ClickHouse 24.3 (default.order_agg)                     # OLAP
  → Superset 3.1.0                                          # dashboards
```

### Catalog / Layer Mapping

| Trino catalog | Layer  | Type            | Location                                      |
|---------------|--------|-----------------|-----------------------------------------------|
| `iceberg`     | Bronze | Physical tables | MinIO `s3://lakehouse/bronze/`                |
| `lakehouse`   | Silver | Trino views     | Hive Metastore (Postgres `metastore` database)|
| `lakehouse`   | Gold   | Trino views     | Hive Metastore (Postgres `metastore` database)|

Silver and gold views are managed by **dbt** (models in `lakehouse-poc/dbt/models/`). They persist across Trino restarts because DDL is stored in HMS, not in memory.

### Key Source Files

| File | Purpose |
|------|---------|
| `lakehouse-poc/flink-jobs/src/main/java/com/lakehouse/KafkaToIcebergJob.java` | Flink DataStream job: Kafka → Iceberg upsert |
| `lakehouse-poc/scripts/bootstrap.sh` | Full orchestration: auth artifacts → services → Flink → Superset |
| `lakehouse-poc/scripts/create-views.sh` | Runs dbt to create/refresh HMS-backed views |
| `lakehouse-poc/scripts/validate.sh` | E2E tests with 90s waits for Flink checkpoint flushes |
| `lakehouse-poc/scripts/check-replication-lag.sh` | WAL lag + connector + Flink health check |
| `lakehouse-poc/dbt/models/` | dbt models: silver (dedup) + gold (aggregation) |
| `lakehouse-poc/airflow/dags/lakehouse_pipeline.py` | Airflow DAG: dbt_run → sync_clickhouse → monitoring_check |
| `lakehouse-poc/hive-metastore/metastore-site.xml` | HMS Postgres backend config |
| `lakehouse-poc/nginx/nginx.conf` | nginx reverse proxy for Flink UI (:8090) and Kafka Connect (:8091) |
| `lakehouse-poc/kafka-connect/debezium-connector.json` | Debezium CDC config |
| `lakehouse-poc/postgres-init/01_init.sql` | Source schema, seed data, WAL config, `dbz_publication` |
| `lakehouse-poc/postgres-init/02_extra_dbs.sql` | Creates `metastore` and `airflow` databases |
| `lakehouse-poc/trino/catalog/iceberg.properties` | Trino→Iceberg REST catalog connection |
| `lakehouse-poc/trino/catalog/lakehouse.properties` | Trino→Hive Metastore (replaces memory connector) |

## Non-Obvious Design Details

- **ClickHouse native port is 19000** (not 9000) — remapped to avoid collision with MinIO host port 9000.
- **Flink job submission goes through nginx** — use `http://localhost:8090/jars/upload` (with basic auth) for REST API calls from the host; Flink internal port 8081 is not exposed directly.
- **Trino views are now persistent** — `lakehouse` catalog uses the Hive connector backed by HMS (Postgres `metastore` DB). Views survive Trino restarts without rerunning any script.
- **Silver deduplication** uses `ROW_NUMBER() OVER (PARTITION BY id ORDER BY updated_at DESC)`, filtering `__op != 'd'`.
- **Debezium decimal mode is `string`** and timestamp mode is `connect` (epoch millis).
- **Flink checkpoint interval is 60s** — mutations take up to 60s to appear in Iceberg. Validation tests wait 90s.
- **Kafka tombstones are filtered** via `NullSafeStringSchema` before JSON parsing.
- **Flink restart strategy** is `fixed-delay`, 3 attempts, 30s delay. Checkpoints in `s3://lakehouse/flink-checkpoints/`, savepoints in `s3://lakehouse/flink-savepoints/`.
- **bootstrap.sh checks Flink job state** before submitting — skips if RUNNING, tries savepoint recovery if FAILED.
- **ClickHouse password** is read from `CLICKHOUSE_PASSWORD` env var via `from_env` in `users.xml`.
- **Trino HTTPS** (`:8443`) uses a self-signed JKS keystore generated by bootstrap.sh. Internal tools use HTTP `:8080` (no auth). `http-server.authentication.allow-insecure-over-http=true` allows both.
- **Airflow** uses LocalExecutor backed by the `airflow` Postgres database (same container, different DB).
- **HMS JDBC driver** (`postgresql-42.6.0.jar`) is downloaded by bootstrap.sh to `hive-metastore/` and mounted into the HMS container.

## Service Ports

| Service                    | URL / Port                           | Auth / Credentials                          |
|----------------------------|--------------------------------------|---------------------------------------------|
| Trino (HTTP, internal)     | http://localhost:8080                | no auth (for scripts, dbt, Airflow)         |
| Trino (HTTPS, external)    | https://localhost:8443               | admin / `TRINO_ADMIN_PASSWORD` (from .env)  |
| Flink UI + REST (nginx)    | http://localhost:8090                | `NGINX_USERNAME` / `NGINX_PASSWORD`         |
| Kafka Connect (nginx)      | http://localhost:8091                | `NGINX_USERNAME` / `NGINX_PASSWORD`         |
| Airflow                    | http://localhost:8089                | admin / `AIRFLOW_ADMIN_PASSWORD`            |
| MinIO Console              | http://localhost:9001                | `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY`     |
| Iceberg REST               | http://localhost:8181                | no auth                                     |
| ClickHouse HTTP            | http://localhost:8123                | default / `CLICKHOUSE_PASSWORD`             |
| Superset                   | http://localhost:8088                | admin / `SUPERSET_ADMIN_PASSWORD`           |
| PostgreSQL                 | localhost:5432                       | `POSTGRES_USER` / `POSTGRES_PASSWORD` / `POSTGRES_DB` |
| Hive Metastore (internal)  | thrift://hive-metastore:9083         | no auth (docker network only)               |
