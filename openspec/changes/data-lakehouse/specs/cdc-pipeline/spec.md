## ADDED Requirements

### Requirement: PostgreSQL configured for logical replication
PostgreSQL 16 SHALL be configured with `wal_level=logical`, `max_replication_slots=5`, and `max_wal_senders=5`. A replication publication named `dbz_publication` SHALL be created for all tables. A dedicated user `lakeuser` with `REPLICATION` privilege SHALL be used.

#### Scenario: Logical replication parameters active
- **WHEN** the Postgres container starts
- **THEN** `SHOW wal_level` returns `logical` and `SELECT count(*) FROM pg_publication WHERE pubname='dbz_publication'` returns 1

#### Scenario: Seed data present at startup
- **WHEN** the init SQL runs
- **THEN** `customers`, `products`, and `orders` tables each have at least 20 rows

### Requirement: Debezium connector registered and running
A Debezium PostgreSQL connector named `pg-lakehouse-connector` SHALL be registered via Kafka Connect REST API (`POST /connectors`). It SHALL use `snapshot.mode=initial` and the `ExtractNewRecordState` SMT to produce flat JSON with `__op` included.

#### Scenario: Connector status is RUNNING
- **WHEN** `GET /connectors/pg-lakehouse-connector/status` is called after registration
- **THEN** the response JSON contains `"state": "RUNNING"` for both connector and all tasks

#### Scenario: CDC topics created after snapshot
- **WHEN** the connector completes its initial snapshot
- **THEN** Kafka topics `cdc.public.customers`, `cdc.public.products`, and `cdc.public.orders` exist and contain at least 20 messages each

#### Scenario: SMT unwrapping produces flat JSON
- **WHEN** a message is consumed from `cdc.public.orders`
- **THEN** the message value is a flat JSON object containing `id`, `customer_id`, `product_id`, `quantity`, `total_amount`, `status`, `created_at`, `updated_at`, and `__op` fields (no `before`/`after` envelope)

### Requirement: Flink CDC-to-Iceberg job running
A Flink DataStream job `KafkaToIcebergJob` SHALL consume from CDC topics, parse Debezium flat JSON, map records to `RowData`, and write to Iceberg bronze tables using `FlinkSink.forRowData()` with `upsert=true` and equality field `id`. Checkpointing SHALL be enabled at 60-second intervals.

#### Scenario: Flink job submitted and running
- **WHEN** the fat JAR is submitted to Flink JobManager REST API
- **THEN** `GET /jobs` returns the job with status `RUNNING`

#### Scenario: INSERT propagates to Iceberg within 90 seconds
- **WHEN** a row is inserted into `orders` in PostgreSQL
- **THEN** within 90 seconds the row is visible via `SELECT * FROM iceberg.bronze.orders` in Trino

#### Scenario: UPDATE propagates to Iceberg within 90 seconds
- **WHEN** an existing order's `status` column is updated in PostgreSQL
- **THEN** within 90 seconds the updated row is reflected in `iceberg.bronze.orders` (upsert on `id`)

#### Scenario: DELETE produces tombstone record in Iceberg
- **WHEN** a customer row is deleted from PostgreSQL
- **THEN** within 90 seconds a record with `__op = 'd'` and the matching `id` is present in `iceberg.bronze.customers`

### Requirement: register-connector.sh script
A script `scripts/register-connector.sh` SHALL register the Debezium connector by POSTing `kafka-connect/debezium-connector.json` to Kafka Connect REST API. It SHALL wait for Kafka Connect to be available before posting and exit non-zero on failure.

#### Scenario: Script succeeds when Kafka Connect is healthy
- **WHEN** `bash scripts/register-connector.sh` is run after Kafka Connect is healthy
- **THEN** the script exits 0 and the connector appears in `GET /connectors`
