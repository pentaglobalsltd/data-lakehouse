# Data Lakehouse POC

A single-VM, fully containerized data lakehouse proof-of-concept demonstrating real-time CDC ingestion, open table format storage, federated analytics, and BI dashboards — all with open-source technologies and a one-command deployment.

## Architecture

```
PostgreSQL (OLTP)
    │  Logical Replication (WAL)
    ▼
Debezium (Kafka Connect)
    │  CDC Events (JSON)
    ▼
Apache Kafka
    │  Topics: cdc.public.{customers, products, orders}
    ▼
Apache Flink (DataStream)
    │  Upsert writes (exactly-once)
    ▼
Apache Iceberg (on MinIO/S3)
    ├── bronze.customers    ─┐
    ├── bronze.products      │  Medallion Architecture
    └── bronze.orders       ─┘
    ▼
Trino (Federated SQL)
    ├── silver.*            (deduplicated views)
    └── gold.order_summary  (aggregated view)
    ▼
ClickHouse (OLAP)  ◄── Materialized aggregations
    ▼
Apache Superset (Dashboards)
```

### Data Flow

1. **PostgreSQL** holds transactional data (customers, products, orders) with logical replication enabled
2. **Debezium** captures every INSERT/UPDATE/DELETE via a CDC connector and publishes to Kafka
3. **Kafka** buffers change events as JSON messages across three topics
4. **Flink** consumes CDC events, maps them to Iceberg RowData, and writes with upsert semantics (equality on `id`)
5. **Iceberg** stores bronze-layer tables on MinIO with ACID guarantees and row-level deletes
6. **Trino** exposes silver (deduplicated) and gold (aggregated) views over Iceberg, and federates queries to ClickHouse
7. **ClickHouse** holds pre-computed OLAP aggregations for fast analytical queries
8. **Superset** connects to Trino and ClickHouse for dashboards and exploration

### Medallion Architecture

| Layer | Location | Description |
|-------|----------|-------------|
| **Bronze** | `iceberg.bronze.{customers,products,orders}` | Raw CDC records with `__op` column for operation type |
| **Silver** | `iceberg.silver.*` (Trino views) | Latest row per ID, deletes excluded |
| **Gold** | `iceberg.gold.order_summary` (Trino view) | Revenue aggregations by city (joined customers + orders) |

## Technology Stack

| Component | Technology | Version |
|-----------|-----------|---------|
| Source Database | PostgreSQL | 16 |
| CDC | Debezium (Kafka Connect) | 2.5 |
| Message Queue | Apache Kafka | 7.6.0 (Confluent) |
| Stream Processing | Apache Flink | 1.18.1 |
| Table Format | Apache Iceberg | 1.5.2 |
| Metadata Catalog | Iceberg REST Catalog | Latest |
| Object Storage | MinIO | 2024-01-16 |
| Query Engine | Trino | 438 |
| OLAP Database | ClickHouse | 24.3 |
| BI / Dashboards | Apache Superset | 3.1.0 |

## Prerequisites

- **OS**: Ubuntu 22.04 (or compatible Linux)
- **RAM**: 32 GB recommended (16 GB minimum)
- **CPU**: 8 vCPU recommended (4 minimum)
- **Disk**: 50+ GB free
- **Software**: Docker and Docker Compose (installed automatically by bootstrap if missing)

## Quick Start

### 1. Clone and Deploy

```bash
git clone <repo-url>
cd data-lake-poc/lakehouse-poc
bash scripts/bootstrap.sh
```

The bootstrap script automates the entire setup (~8–10 minutes):

1. Installs Docker Engine and Java 11 + Maven (if not present)
2. Starts all 12 services via `docker compose up -d`
3. Waits for health checks on all services
4. Registers the Debezium CDC connector
5. Builds and submits the Flink streaming job
6. Waits for initial data to land in Iceberg bronze tables
7. Creates silver and gold Trino views
8. Sets up ClickHouse aggregation table
9. Registers Superset datasources

### 2. Validate the Pipeline

```bash
bash scripts/validate.sh
```

Runs end-to-end tests:

- **INSERT**: New order → appears in Iceberg bronze within 30s
- **UPDATE**: Order status change → reflected in Iceberg
- **DELETE**: Customer deletion → tombstone record (`__op='d'`) in Iceberg
- **ClickHouse**: Aggregation table populated correctly

### 3. Access the UIs

| Service | URL | Credentials |
|---------|-----|-------------|
| Flink Dashboard | http://localhost:8082 | — |
| Trino UI | http://localhost:8080 | — |
| MinIO Console | http://localhost:9001 | `minioadmin` / `minioadmin123` |
| ClickHouse HTTP | http://localhost:8123 | — |
| Superset | http://localhost:8088 | `admin` / `admin` |

### 4. Cleanup

```bash
cd lakehouse-poc
docker compose down -v
```

## Project Structure

```
data-lake-poc/
└── lakehouse-poc/
    ├── docker-compose.yml              # All 12 services
    ├── postgres-init/
    │   └── 01_init.sql                 # Schema, seed data, replication setup
    ├── kafka-connect/
    │   └── debezium-connector.json     # CDC connector configuration
    ├── flink-jobs/
    │   ├── pom.xml                     # Maven build (fat JAR via Shade)
    │   └── src/main/java/com/lakehouse/
    │       └── KafkaToIcebergJob.java  # Flink streaming job
    ├── trino/
    │   ├── config.properties           # Coordinator config
    │   └── catalog/
    │       ├── iceberg.properties      # Iceberg REST catalog connector
    │       └── clickhouse.properties   # ClickHouse JDBC connector
    ├── clickhouse/
    │   └── config.xml                  # Server configuration
    ├── superset/
    │   └── superset_config.py          # App configuration
    └── scripts/
        ├── bootstrap.sh                # One-command deployment
        ├── register-connector.sh       # Debezium connector registration
        └── validate.sh                 # End-to-end pipeline validation
```

## Services & Ports

| Service | Host Port | Purpose |
|---------|-----------|---------|
| PostgreSQL | 5432 | Source OLTP database |
| Kafka | 29092 | Broker API (host access) |
| Kafka Connect | 8083 | Debezium REST API |
| Flink JobManager | 8082 | Web UI and job submission |
| MinIO S3 API | 9000 | Object storage |
| MinIO Console | 9001 | Storage management UI |
| Iceberg REST | 8181 | Table metadata catalog |
| Trino | 8080 | SQL query engine |
| ClickHouse HTTP | 8123 | OLAP HTTP API |
| ClickHouse Native | 19000 | Native protocol |
| Superset | 8088 | BI dashboards |

## Key Configuration Details

### PostgreSQL

- Database: `lakedb`, User: `lakeuser`, Password: `lakepass`
- WAL level set to `logical` with 5 replication slots
- Publication `dbz_publication` covers all tables
- Seed data: 25 customers, 25 products, 25 orders (Bangladeshi e-commerce dataset)

### Debezium CDC Connector

- Snapshot mode: `initial` (captures existing rows, then streams changes)
- SMT: `ExtractNewRecordState` unwraps the CDC envelope to flat JSON
- Delete handling: `rewrite` mode (adds `__deleted` field for tombstones)

### Flink Streaming Job

- Consumes 3 Kafka topics starting from earliest offset
- Maps Debezium JSON to Iceberg RowData with per-table schemas
- Upsert mode with equality on `id` field (Iceberg format v2)
- Checkpointing: 60-second interval, exactly-once semantics
- State backend: MinIO S3

### Trino

- Catalogs: `iceberg` (REST) and `clickhouse` (JDBC)
- Query memory: 4 GB max total, 2 GB per node
- Silver/gold views created during bootstrap

### ClickHouse

- Aggregation table `default.order_agg` populated from Trino gold view
- Memory limit: 25% of system RAM

## Querying Data

Connect to Trino (port 8080) with any SQL client:

```sql
-- Bronze: raw CDC records
SELECT * FROM iceberg.bronze.orders LIMIT 10;

-- Silver: deduplicated, latest state
SELECT * FROM iceberg.silver.customers;

-- Gold: aggregated analytics
SELECT * FROM iceberg.gold.order_summary ORDER BY total_revenue DESC;

-- Cross-engine: query ClickHouse from Trino
SELECT * FROM clickhouse.default.order_agg;
```

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Iceberg REST Catalog over Hive Metastore | Simpler single-container deployment, no HMS dependency |
| Flink DataStream API over Flink SQL | Direct RowData mapping with explicit schema control |
| MinIO with path-style access | No DNS or virtual-host configuration needed |
| Trino views for silver/gold layers | No data duplication, fast iteration for POC |
| Debezium `ExtractNewRecordState` SMT | Flat JSON avoids complex envelope parsing in Flink |
| ClickHouse aggregations via Trino INSERT | Leverages Trino's federated query capabilities |
