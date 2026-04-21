# Data Lakehouse POC

A single-VM, fully containerized data lakehouse proof-of-concept demonstrating real-time CDC ingestion, open table format storage, federated analytics, scheduled orchestration, and BI dashboards — all with open-source technologies and a one-command deployment.

## Architecture

```
PostgreSQL 16 (OLTP source)
    │  Logical Replication (WAL)
    ▼
Debezium 2.5 (Kafka Connect) ◄── nginx :8091 (basic auth)
    │  CDC Events (JSON)
    ▼
Apache Kafka 7.6.0
    │  Topics: cdc.public.{customers, products, orders}
    ▼
Apache Flink 1.18.1 (DataStream) ◄── Flink UI via nginx :8090 (basic auth)
    │  Upsert writes, exactly-once, checkpoint recovery
    ▼
Apache Iceberg 1.5.2 (on MinIO S3)
    ├── bronze.customers  ─┐
    ├── bronze.products    │  Medallion Architecture
    └── bronze.orders     ─┘
    ▼
Hive Metastore 3.1.3 (view DDL persistence)
    ▼
Trino 438 (Federated SQL)  :8080 internal / :8443 HTTPS+auth
    ├── silver.*            (dbt-managed, dedup views)
    └── gold.order_summary  (dbt-managed, aggregated view)
    ▼
Airflow 2.8.1 (30-min schedule) :8089
    │  dbt run → ClickHouse sync → monitoring check
    ▼
ClickHouse 24.3 (OLAP)
    ▼
Apache Superset 3.1.0 (Dashboards) :8088
```

### Data Flow

1. **PostgreSQL** holds transactional data with logical replication enabled
2. **Debezium** captures every INSERT/UPDATE/DELETE and publishes to Kafka
3. **Kafka** buffers change events across three topics as flat JSON
4. **Flink** consumes CDC events, maps them to Iceberg RowData, and writes with upsert semantics; restarts automatically (fixed-delay, 3 attempts) and recovers from checkpoints/savepoints in MinIO
5. **Iceberg** stores bronze-layer tables on MinIO with ACID guarantees
6. **Hive Metastore** persists the DDL of silver and gold Trino views so they survive container restarts
7. **dbt** manages silver (dedup) and gold (aggregation) view definitions; Airflow runs `dbt run` on schedule
8. **Airflow** orchestrates: dbt refresh → ClickHouse sync → health monitoring every 30 minutes
9. **ClickHouse** holds pre-computed OLAP aggregations for fast analytical queries
10. **Superset** connects to Trino and ClickHouse for dashboards

### Medallion Architecture

| Layer | Location | Description |
|-------|----------|-------------|
| **Bronze** | `iceberg.bronze.{customers,products,orders}` | Raw CDC records with `__op` column (`c/u/d`) |
| **Silver** | `lakehouse.silver.*` (HMS-backed Trino views) | Latest row per ID, deletes excluded, dedup via `ROW_NUMBER()` |
| **Gold** | `lakehouse.gold.order_summary` (HMS-backed Trino view) | Revenue aggregations by city |

Silver and gold views are managed by **dbt** and stored in Hive Metastore — they **persist across Trino restarts** without rerunning any script.

## Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Source Database | PostgreSQL | 16 |
| CDC | Debezium (Kafka Connect) | 2.5 |
| Message Queue | Apache Kafka | 7.6.0 (Confluent) |
| Stream Processing | Apache Flink | 1.18.1 |
| Table Format | Apache Iceberg | 1.5.2 |
| REST Catalog | Iceberg REST Catalog | Latest |
| View Metadata | Hive Metastore | 3.1.3 |
| Object Storage | MinIO | 2024-01-16 |
| Query Engine | Trino | 438 |
| View Transforms | dbt (dbt-trino adapter) | 1.7+ |
| Orchestration | Apache Airflow | 2.8.1 |
| Auth Proxy | nginx | Alpine |
| OLAP Database | ClickHouse | 24.3 |
| BI / Dashboards | Apache Superset | 3.1.0 |

## Prerequisites

- **OS**: Ubuntu 22.04 (or compatible Linux)
- **RAM**: 32 GB recommended (16 GB minimum)
- **CPU**: 8 vCPU recommended (4 minimum)
- **Disk**: 50+ GB free
- **Software**: Docker and Docker Compose (installed automatically by bootstrap if missing)

## Quick Start

### 1. Configure Credentials

```bash
cd data-lake-poc/lakehouse-poc
cp .env.example .env
# Edit .env and set secure passwords for all services
```

The stack works with the default values in `.env.example` for local testing — change them before any shared or internet-facing deployment.

### 2. Deploy

```bash
bash scripts/bootstrap.sh
```

Bootstrap automates the entire setup (~12–15 minutes):

1. Installs Docker Engine and Java 11 + Maven (if not present)
2. Generates auth artifacts — nginx `.htpasswd`, Trino TLS keystore, Trino `password.db` (bcrypt), HMS JDBC driver download
3. Starts all services via `docker compose up -d`
4. Waits for health checks in dependency order (Postgres → Kafka → MinIO → HMS → Flink → Trino → Airflow → Superset)
5. Registers the Debezium CDC connector (through the nginx proxy)
6. Builds and submits the Flink streaming job (skips if already RUNNING; recovers from savepoint if FAILED)
7. Waits for initial data to land in Iceberg bronze tables
8. Creates the ClickHouse aggregation table schema
9. Registers Superset datasources

> **ClickHouse population** is handled by the Airflow DAG (`lakehouse_pipeline`) on its first 30-minute run, or trigger it manually from the Airflow UI at http://localhost:8089.

### 3. Validate the Pipeline

```bash
bash scripts/validate.sh
```

Runs end-to-end tests: INSERT → CDC → Iceberg, UPDATE propagation, DELETE tombstone, and ClickHouse sync.

### 4. Check Service Health

```bash
bash scripts/check-replication-lag.sh
```

Reports PostgreSQL WAL replication lag, Kafka Connect connector state, and Flink job state. Exits non-zero if anything is unhealthy. Also runs automatically as the `monitoring_check` task in the Airflow DAG.

### 5. Cleanup

```bash
docker compose down -v    # removes containers and all volumes
```

## Accessing Services

All credentials come from `.env`. Defaults shown below.

| Service | URL | Auth |
|---------|-----|------|
| Flink UI + REST API | http://localhost:8090 | `admin` / `NGINX_PASSWORD` (basic auth via nginx) |
| Kafka Connect REST | http://localhost:8091 | `admin` / `NGINX_PASSWORD` (basic auth via nginx) |
| Trino (internal / scripts) | http://localhost:8080 | no auth |
| Trino (external / admin) | https://localhost:8443 | `admin` / `TRINO_ADMIN_PASSWORD` |
| Airflow | http://localhost:8089 | `admin` / `AIRFLOW_ADMIN_PASSWORD` |
| MinIO Console | http://localhost:9001 | `MINIO_ACCESS_KEY` / `MINIO_SECRET_KEY` |
| Iceberg REST Catalog | http://localhost:8181 | no auth |
| ClickHouse HTTP | http://localhost:8123 | `default` / `CLICKHOUSE_PASSWORD` |
| Superset | http://localhost:8088 | `admin` / `SUPERSET_ADMIN_PASSWORD` |
| PostgreSQL | localhost:5432 | `lakeuser` / `lakepass` / `lakedb` |

## Project Structure

```
data-lake-poc/
├── README.md
└── lakehouse-poc/
    ├── docker-compose.yml              # ~18 services
    ├── .env.example                    # Credential template (copy → .env)
    ├── .gitignore                      # Ignores .env, generated auth files, JARs
    ├── postgres-init/
    │   ├── 01_init.sql                 # Schema, seed data, WAL config, publication
    │   └── 02_extra_dbs.sql            # Creates metastore + airflow databases
    ├── kafka-connect/
    │   └── debezium-connector.json     # CDC connector configuration
    ├── flink-jobs/
    │   ├── pom.xml                     # Maven build (fat JAR via Shade plugin)
    │   └── src/main/java/com/lakehouse/
    │       └── KafkaToIcebergJob.java  # Flink streaming job
    ├── hive-metastore/
    │   ├── entrypoint.sh               # Handles JDBC driver, schema init, service start
    │   └── metastore-site.xml          # HMS Postgres backend config
    ├── dbt/
    │   ├── dbt_project.yml
    │   ├── profiles.yml                # Connects to Trino HTTP :8080
    │   └── models/
    │       ├── sources.yml             # iceberg.bronze.* source definitions
    │       ├── silver/                 # customers, orders, products (dedup views)
    │       └── gold/                   # order_summary (aggregation view)
    ├── airflow/
    │   └── dags/
    │       └── lakehouse_pipeline.py   # 30-min DAG: dbt → ClickHouse → monitoring
    ├── nginx/
    │   └── nginx.conf                  # Reverse proxy with basic auth
    ├── trino/
    │   ├── config.properties           # HTTP :8080 + HTTPS :8443, password auth
    │   ├── password-authenticator.properties
    │   └── catalog/
    │       ├── iceberg.properties      # Iceberg REST catalog connector
    │       ├── lakehouse.properties    # Hive connector → HMS
    │       └── clickhouse.properties   # ClickHouse JDBC connector
    ├── clickhouse/
    │   ├── config.xml                  # Server configuration
    │   └── users.xml                   # Password via CLICKHOUSE_PASSWORD env var
    ├── superset/
    │   └── superset_config.py
    └── scripts/
        ├── bootstrap.sh                # One-command deployment
        ├── register-connector.sh       # Debezium connector registration (auth-aware)
        ├── create-views.sh             # Runs dbt to refresh views
        ├── validate.sh                 # End-to-end pipeline validation
        └── check-replication-lag.sh    # WAL lag + service health check
```

## Querying Data

All internal tooling (Flink submission, dbt, Airflow, validate.sh) uses Trino HTTP on port 8080 without auth. External / browser access uses HTTPS on port 8443 with the admin password.

```sql
-- Bronze: raw CDC records (all operations including deletes)
SELECT * FROM iceberg.bronze.orders LIMIT 10;

-- Silver: deduplicated, latest state per ID, deletes excluded
SELECT * FROM lakehouse.silver.customers;

-- Gold: aggregated analytics
SELECT * FROM lakehouse.gold.order_summary ORDER BY total_revenue DESC;

-- Cross-engine: query ClickHouse from Trino
SELECT * FROM clickhouse.default.order_agg;
```

Direct ClickHouse query (with password):
```bash
curl -u "default:${CLICKHOUSE_PASSWORD}" http://localhost:8123/ \
  -d "SELECT * FROM default.order_agg ORDER BY total_revenue DESC"
```

## Key Configuration Details

### PostgreSQL

- Databases: `lakedb` (source data), `metastore` (Hive Metastore schema), `airflow` (Airflow metadata)
- Single container, three databases — no extra Postgres containers
- WAL level: `logical`, 5 replication slots, `max_connections=200`
- Seed data: 25 customers, 25 products, 25 orders (Bangladeshi e-commerce dataset)

### Debezium CDC Connector

- External access via nginx proxy at `:8091` (basic auth)
- Snapshot mode: `initial`, then streams all changes
- SMT: `ExtractNewRecordState` flattens CDC envelope to plain JSON with `__op` field
- Delete handling: `rewrite` mode emits a record with `__op=d` before tombstone

### Flink Streaming Job

- Parallelism: 1 (ordered CDC processing)
- Checkpoints: 60s interval, exactly-once, stored in `s3://lakehouse/flink-checkpoints/`
- Savepoints: `s3://lakehouse/flink-savepoints/`
- Restart strategy: `fixed-delay`, 3 attempts, 30s delay
- Flink UI exposed via nginx at `:8090` — raw port 8081 not bound to host
- bootstrap.sh checks job state before submission: skips if RUNNING, recovers from savepoint if FAILED

### Hive Metastore

- Image: `apache/hive:3.1.3`
- Backend: existing Postgres container, `metastore` database
- Stores view DDL for `lakehouse.silver.*` and `lakehouse.gold.*`
- PostgreSQL JDBC driver downloaded by bootstrap.sh and mounted as a volume

### dbt

- Adapter: `dbt-trino`, connects to Trino HTTP `:8080`
- Materialization: `view` for all models (no data duplication)
- Run at bootstrap via `dbt-init` container; subsequently by Airflow every 30 minutes
- Retry loop handles the case where bronze tables don't exist yet when dbt first runs

### Trino

- Catalogs: `iceberg` (REST), `lakehouse` (Hive connector → HMS), `clickhouse` (JDBC)
- HTTP `:8080`: no auth — used by internal tools (dbt, Airflow, validate.sh, Superset)
- HTTPS `:8443`: password file auth (bcrypt) — for external admin access; self-signed JKS cert

### Airflow

- Executor: LocalExecutor (no Celery, no Redis)
- Metadata DB: Postgres `airflow` database (same container as source data)
- DAG `lakehouse_pipeline` runs every 30 minutes: `dbt_run` → `sync_clickhouse` → `monitoring_check`
- ClickHouse sync: TRUNCATE then INSERT SELECT from `lakehouse.gold.order_summary` (idempotent)

### ClickHouse

- Native TCP port remapped to `19000` to avoid collision with MinIO's host port `9000`
- Password set via `CLICKHOUSE_PASSWORD` environment variable (`from_env` in users.xml)
- Memory limit: 25% of system RAM

### Monitoring

`check-replication-lag.sh` checks three things:
1. PostgreSQL WAL lag per replication slot (fails if > 500 MB)
2. Kafka Connect connector state (must be `RUNNING`)
3. Flink job count (must have at least one `RUNNING` job)

Set `SLACK_WEBHOOK_URL` in `.env` to receive alerts on failure. The check runs automatically as `monitoring_check` in the Airflow DAG and can be invoked standalone from the host.

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Hive Metastore for view persistence | Trino views in HMS survive restarts; memory connector does not |
| dbt for view management | Version-controlled SQL, lineage tracking, retry logic for startup ordering |
| Airflow LocalExecutor over Celery | No Redis dependency; sufficient for single-VM POC |
| Single Postgres, three databases | Avoids additional container; metastore + airflow schemas are lightweight |
| Flink via REST (no custom Docker image) | Fat JAR upload keeps the image standard; easier to iterate |
| nginx basic auth for Flink + Kafka Connect | Lightweight protection without adding an auth service |
| Trino HTTP for internal + HTTPS for external | Avoids breaking all internal tooling while adding external auth |
| ClickHouse sync via Trino INSERT SELECT | Leverages existing Trino federated query; idempotent with TRUNCATE-first |
| Savepoints in MinIO | Co-located with checkpoints; no ZooKeeper or external HA coordinator needed |
