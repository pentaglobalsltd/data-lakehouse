## Context

This design covers a single-VM open-source data lakehouse POC. The target is a fresh Ubuntu 22.04 host with 32 GB RAM / 8 vCPU. All services run as Docker containers coordinated by Docker Compose. There is no existing infrastructure to migrate from; this is a greenfield deployment.

The primary constraint is that everything must work with `bash scripts/bootstrap.sh` and result in a fully operational pipeline where PostgreSQL mutations flow to queryable Iceberg tables within ~60 seconds.

## Goals / Non-Goals

**Goals:**
- Full CDC pipeline: PostgreSQL 16 → Debezium/Kafka Connect → Kafka → Flink 1.18 → Iceberg (MinIO) within ~60 s latency
- Medallion architecture: bronze (raw CDC via Flink), silver (Trino views), gold (Trino views)
- Federated query: Trino with both `iceberg` and `clickhouse` catalogs
- OLAP aggregations in ClickHouse 24.3
- Superset 3.1 pre-configured with Trino + ClickHouse datasources
- One-command bootstrap and automated end-to-end validation

**Non-Goals:**
- High-availability or multi-node deployment
- Schema registry (Avro/Protobuf) — plain JSON CDC is sufficient for POC
- Kubernetes, Helm, or cloud deployment
- Production security hardening (TLS, secrets management, RBAC)
- Incremental/streaming silver and gold layers — Trino views suffice for POC

## Decisions

### 1. Iceberg REST Catalog over Hive Metastore
**Decision**: Use `tabulario/iceberg-rest` as the catalog server.
**Rationale**: Hive Metastore requires a separate RDBMS and is heavyweight for a POC. The REST catalog is a single container, needs no external DB, and is natively supported by both Flink's `IcebergSink` and Trino's Iceberg connector.
**Alternative considered**: Nessie catalog — adds branching/tagging features not needed here, and has a larger footprint.

### 2. Flink DataStream API over Table/SQL API
**Decision**: Write `KafkaToIcebergJob.java` using the DataStream API with `FlinkSink.forRowData()`.
**Rationale**: The DataStream API gives explicit control over schema registration, `RowData` mapping, and upsert equality fields. The SQL API's Kafka connector requires a schema registry for Debezium JSON, adding complexity.
**Alternative considered**: Flink SQL with `CREATE TABLE … WITH ('connector'='kafka')` — rejected because SMT-unwrapped JSON still needs a manually-declared schema, and SQL jobs are harder to fat-JAR package for REST submission.

### 3. MinIO with Path-Style Access
**Decision**: Configure all S3 clients (Flink S3FileIO, Iceberg REST catalog, Trino) to use `s3.path-style-access=true` pointing at `http://minio:9000`.
**Rationale**: MinIO does not support virtual-hosted-style bucket addressing in single-node mode without DNS configuration. Path-style access works out of the box.

### 4. ClickHouse Native Port Remapped to 19000
**Decision**: Map ClickHouse's native TCP port 9000 → host port 19000 in Docker Compose.
**Rationale**: MinIO already occupies host port 9000. Both services use 9000 internally; the remap avoids a host-port conflict while keeping intra-network communication unchanged (Trino ClickHouse connector uses HTTP port 8123, not native 9000).

### 5. Flink Fat JAR Built Locally, Submitted via REST
**Decision**: `bootstrap.sh` runs `mvn package -f flink-jobs/pom.xml` to produce a shaded fat JAR, then POSTs it to Flink JobManager REST API (`/jars/upload`, `/jars/{id}/run`).
**Rationale**: Baking the JAR into the Flink Docker image would require a custom image build and registry. REST submission allows the JAR to be rebuilt and resubmitted without restarting containers.

### 6. Debezium `snapshot.mode=initial` with `ExtractNewRecordState` SMT
**Decision**: Use `snapshot.mode=initial` so the connector snapshots all existing rows before streaming changes. Apply `io.debezium.transforms.ExtractNewRecordState` SMT with `add.fields=op` to produce flat JSON with `__op` included.
**Rationale**: Ensures bronze tables are seeded with existing data, not just future mutations. Flat JSON simplifies Flink deserialization — no envelope unwrapping needed in Java code.

### 7. Trino Views for Silver and Gold
**Decision**: Define silver and gold layers as Trino `CREATE OR REPLACE VIEW` statements, not as Flink jobs writing separate Iceberg tables.
**Rationale**: For a POC, views are sufficient and avoid duplicating data. A production system would use a scheduled Flink or dbt job to materialize these layers.

## Risks / Trade-offs

- **[Risk] MinIO single-node has no replication** → Mitigation: Acceptable for POC; data loss on VM failure is tolerable.
- **[Risk] Flink checkpointing to MinIO (S3) may be slow on spinning disk** → Mitigation: Checkpoint interval set to 60 s; reduce parallelism to 1 to minimize I/O contention.
- **[Risk] Iceberg REST catalog stores metadata in-memory by default (`tabulario/iceberg-rest`)** → Mitigation: Mount a local volume for the catalog's warehouse directory; metadata is also persisted as Iceberg metadata JSON files in MinIO.
- **[Risk] ClickHouse native port collision with MinIO** → Mitigation: Remapped to 19000 on host (see Decision 4).
- **[Risk] Bootstrap script is not idempotent on partial failure** → Mitigation: Script checks for existing containers/connectors before re-registering; MVP acceptance — full re-run on failure is documented.
- **[Risk] 32 GB RAM may be tight with all services running simultaneously** → Mitigation: JVM heap limits set explicitly in Docker Compose (`-Xmx` for Flink, Kafka, Connect); Superset and ClickHouse have relatively low footprints.

## Migration Plan

1. Run `bash scripts/bootstrap.sh` on a fresh Ubuntu 22.04 VM.
2. Script installs Docker, Java 11, Maven; starts all services; registers connector; submits Flink job.
3. Run `bash scripts/validate.sh` to confirm end-to-end pipeline.
4. Access Superset at `http://<vm-ip>:8088` (admin/admin) for dashboards.

**Rollback**: `docker compose down -v` in `lakehouse-poc/` removes all containers and volumes. No host-level state is modified beyond Docker and Java installations.

## Open Questions

- Should the Iceberg REST catalog be replaced with Nessie for branching capability in a follow-up? (Not needed for POC.)
- Should silver/gold layers be materialized as scheduled Flink jobs or dbt models in a production follow-up?
