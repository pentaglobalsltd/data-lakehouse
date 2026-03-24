## Why

Modern data teams need a unified analytical platform that captures every INSERT/UPDATE/DELETE from an operational database in real time, stores it durably in an open table format, and exposes it for both ad-hoc SQL queries and OLAP dashboards — without a managed cloud service. This POC proves the full open-source lakehouse stack is runnable on a single VM with one command.

## What Changes

- **New**: Full Docker Compose project (`lakehouse-poc/`) deployable on Ubuntu 22.04 with a single `bash scripts/bootstrap.sh`
- **New**: PostgreSQL 16 source database configured for logical replication with a Bangladeshi e-commerce seed dataset (customers, products, orders — 20+ rows each)
- **New**: Debezium PostgreSQL connector streaming CDC events (INSERT/UPDATE/DELETE) to Kafka topics with `ExtractNewRecordState` SMT unwrapping
- **New**: Apache Flink 1.18 DataStream job (`KafkaToIcebergJob.java`) consuming CDC topics and writing to Iceberg bronze tables via REST catalog with upsert semantics
- **New**: Apache Iceberg REST catalog backed by MinIO (S3-compatible) with three medallion layers: bronze (raw CDC), silver (Trino views, deduplicated), gold (Trino views, joined)
- **New**: Trino 438 with `iceberg` and `clickhouse` catalogs for federated SQL queries across both stores
- **New**: ClickHouse 24.3 for OLAP aggregations, pre-populated from Iceberg data
- **New**: Apache Superset 3.1 dashboard connected to both Trino and ClickHouse as datasources
- **New**: `validate.sh` end-to-end test covering INSERT → CDC → Flink → Iceberg → Trino, UPDATE flow, and DELETE tombstone verification

## Capabilities

### New Capabilities

- `cdc-pipeline`: Logical replication from PostgreSQL through Debezium/Kafka to Iceberg bronze layer via Flink, including connector registration and job submission
- `iceberg-storage`: Iceberg REST catalog on MinIO with bronze/silver/gold medallion structure, Trino-queryable via S3FileIO with path-style access
- `olap-query-layer`: ClickHouse OLAP engine and Trino federated query layer with pre-configured catalogs
- `dashboard-layer`: Superset connected to Trino and ClickHouse with datasources pre-configured
- `project-scaffold`: Docker Compose orchestration, bootstrap automation, and end-to-end validation scripts

### Modified Capabilities

## Impact

- **New project directory**: `lakehouse-poc/` at repo root — no existing code modified
- **Dependencies introduced**: Docker Engine 24+, Docker Compose plugin, Java 11, Maven 3.8+
- **Ports consumed on host**: 5432 (Postgres), 9092 (Kafka), 8083 (Kafka Connect), 8081/8082 (Flink), 9000/9001 (MinIO), 8181 (Iceberg REST), 8080 (Trino), 8123 (ClickHouse HTTP), 9000 (ClickHouse native — conflicts with MinIO native; ClickHouse native remapped to 19000), 8088 (Superset)
- **Resource requirement**: 32 GB RAM, 8 vCPU recommended; all services share a single Docker network named `lakehouse`
