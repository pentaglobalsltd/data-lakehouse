## 1. Project Scaffold & Docker Compose

- [x] 1.1 Create `lakehouse-poc/` directory structure with all subdirectories (`postgres-init/`, `kafka-connect/`, `trino/catalog/`, `clickhouse/`, `superset/`, `flink-jobs/src/main/java/com/lakehouse/`, `scripts/`)
- [x] 1.2 Write `docker-compose.yml` with all 12 services (`postgres`, `zookeeper`, `kafka`, `kafka-connect`, `iceberg-rest`, `minio`, `minio-init`, `flink-jobmanager`, `flink-taskmanager`, `trino`, `clickhouse`, `superset`) on the `lakehouse` network with correct port mappings and health checks
- [x] 1.3 Configure JVM heap limits in Docker Compose for Kafka (`-Xmx1g`), Kafka Connect (`-Xmx1g`), Flink JobManager (`-Xmx1g`), and Flink TaskManager (`-Xmx2g`) to fit within 32 GB RAM budget

## 2. PostgreSQL Initialization

- [x] 2.1 Write `postgres-init/01_init.sql` with `wal_level=logical`, `max_replication_slots=5`, `max_wal_senders=5` via `ALTER SYSTEM` commands and `pg_reload_conf()`
- [x] 2.2 Create `lakeuser` role with `REPLICATION` and `LOGIN` privileges in init SQL
- [x] 2.3 Create `customers`, `products`, and `orders` tables with the required schemas (including `created_at`, `updated_at` columns)
- [x] 2.4 Seed `customers` table with 20+ rows of realistic Bangladeshi names, emails, and cities (Dhaka, Chittagong, Sylhet, Rajshahi, etc.)
- [x] 2.5 Seed `products` table with 20+ rows of e-commerce products with Bangladeshi categories and BDT prices
- [x] 2.6 Seed `orders` table with 20+ rows referencing seeded customers and products
- [x] 2.7 Create publication `dbz_publication FOR ALL TABLES` in init SQL

## 3. Kafka Connect & Debezium Connector

- [x] 3.1 Write `kafka-connect/debezium-connector.json` with connector class `io.debezium.connector.postgresql.PostgresConnector`, `snapshot.mode=initial`, topic prefix `cdc`, and `ExtractNewRecordState` SMT with `add.fields=op`
- [x] 3.2 Ensure SMT config sets `unwrap.delete.tombstone.handling.mode=rewrite` so deleted records retain `__op=d` instead of being nulled

## 4. Iceberg REST Catalog & MinIO Configuration

- [x] 4.1 Configure Iceberg REST catalog service in Docker Compose using `tabulario/iceberg-rest` image with `CATALOG_WAREHOUSE=s3://lakehouse/`, MinIO endpoint, and credentials `minioadmin`/`minioadmin123`
- [x] 4.2 Add `minio-init` init container to Docker Compose that uses `mc` to create the `lakehouse` bucket after MinIO starts

## 5. Flink DataStream Job

- [x] 5.1 Write `flink-jobs/pom.xml` with dependencies: `flink-java`, `flink-streaming-java`, `flink-connector-kafka`, `iceberg-flink-runtime-1.18`, `hadoop-aws` (for S3FileIO), shaded fat-JAR plugin (`maven-shade-plugin`)
- [x] 5.2 Write `KafkaToIcebergJob.java` that creates a `StreamExecutionEnvironment` with 60-second checkpointing and parallelism 1
- [x] 5.3 Implement Kafka source in `KafkaToIcebergJob.java` consuming topics `cdc.public.customers`, `cdc.public.products`, `cdc.public.orders` using `KafkaSource` with group ID `flink-lakehouse`
- [x] 5.4 Implement Debezium flat JSON parser in `KafkaToIcebergJob.java` using Jackson to deserialize each message into a `Map<String, Object>` and map to `RowData` with correct Iceberg schema types
- [x] 5.5 Implement Iceberg catalog initialization in `KafkaToIcebergJob.java`: connect to REST catalog at `http://iceberg-rest:8181`, configure `S3FileIO` with MinIO endpoint and path-style access
- [x] 5.6 Implement auto-create logic for `bronze.customers`, `bronze.products`, `bronze.orders` tables if they don't exist, with schemas matching PostgreSQL columns plus `__op STRING`
- [x] 5.7 Wire `FlinkSink.forRowData()` for each topic/table with `upsert=true` and `equalityFieldColumns=["id"]`

## 6. Trino Configuration

- [x] 6.1 Write `trino/config.properties` with coordinator mode, HTTP port 8080, and appropriate memory settings
- [x] 6.2 Write `trino/catalog/iceberg.properties` with `connector.name=iceberg`, `iceberg.catalog.type=rest`, `iceberg.rest-catalog.uri=http://iceberg-rest:8181`, and S3/MinIO path-style access config
- [x] 6.3 Write `trino/catalog/clickhouse.properties` with `connector.name=clickhouse` and `connection-url=jdbc:clickhouse://clickhouse:8123/default`
- [x] 6.4 Add silver layer Trino view DDL to bootstrap (or a separate SQL file): `CREATE OR REPLACE VIEW iceberg.silver.orders AS SELECT ... FROM iceberg.bronze.orders WHERE __op != 'd'` with deduplication by `id` using `ROW_NUMBER()`
- [x] 6.5 Add gold layer Trino view DDL: `CREATE OR REPLACE VIEW iceberg.gold.order_summary AS SELECT c.city, sum(o.total_amount) AS total_revenue, count(o.id) AS order_count FROM iceberg.silver.orders o JOIN iceberg.silver.customers c ON o.customer_id = c.id GROUP BY c.city`

## 7. ClickHouse Configuration

- [x] 7.1 Write `clickhouse/config.xml` with HTTP port 8123, native TCP port 9000, and max memory settings appropriate for a 32 GB VM
- [x] 7.2 Add ClickHouse `order_agg` table creation and population SQL to bootstrap: create table with `(city String, total_revenue Float64, order_count UInt64, avg_order_value Float64)` engine MergeTree
- [x] 7.3 Populate `order_agg` via Trino JDBC or ClickHouse HTTP API by querying the gold view after Iceberg tables are seeded

## 8. Superset Configuration

- [x] 8.1 Write `superset/superset_config.py` with `SECRET_KEY`, `SQLALCHEMY_DATABASE_URI` (SQLite for POC), and Trino/ClickHouse datasource URIs
- [x] 8.2 Configure Superset Docker Compose service to run `superset db upgrade && superset fab create-admin --username admin --password admin && superset init` on first start
- [x] 8.3 Add Superset datasource registration to bootstrap: use Superset REST API to POST database connections for `Trino - Lakehouse` and `ClickHouse - Lakehouse`

## 9. Bootstrap Script

- [x] 9.1 Write `scripts/bootstrap.sh` with Docker Engine + Compose plugin installation via `apt-get` (official Docker apt repo)
- [x] 9.2 Add OpenJDK 11 + Maven 3.8 installation to `bootstrap.sh` via `apt-get`
- [x] 9.3 Add `docker compose up -d` invocation with per-service health wait loops (poll `docker inspect --format='{{.State.Health.Status}}'` until `healthy`)
- [x] 9.4 Add connector registration step to `bootstrap.sh` that calls `scripts/register-connector.sh`
- [x] 9.5 Add Flink fat JAR build step: `mvn package -f flink-jobs/pom.xml -DskipTests`
- [x] 9.6 Add Flink JAR submission step: `POST /jars/upload` then `POST /jars/{id}/run` with main class `com.lakehouse.KafkaToIcebergJob`
- [x] 9.7 Add silver/gold Trino view creation step to `bootstrap.sh` using `trino --server http://localhost:8080 --execute "..."`
- [x] 9.8 Add ClickHouse `order_agg` population step to `bootstrap.sh`
- [x] 9.9 Add Superset datasource registration step to `bootstrap.sh`

## 10. Register Connector Script

- [x] 10.1 Write `scripts/register-connector.sh` that polls `GET http://localhost:8083/connectors` until HTTP 200, then POSTs `kafka-connect/debezium-connector.json` and verifies connector status is `RUNNING`

## 11. Validate Script

- [x] 11.1 Write `scripts/validate.sh` that inserts a test order row into PostgreSQL via `psql` and records the inserted `id`
- [x] 11.2 Add 30-second wait then Trino query to check `SELECT count(*) FROM iceberg.bronze.orders WHERE id = <test_id>` — print `[PASS]` or `[FAIL]`
- [x] 11.3 Add ClickHouse HTTP check: `SELECT count(*) FROM default.order_agg` — print `[PASS]` if count > 0
- [x] 11.4 Add UPDATE step: `UPDATE orders SET status = 'shipped' WHERE id = <test_id>`, wait 30s, re-query Trino — print `[PASS]` if status is `shipped`
- [x] 11.5 Add DELETE tombstone check: delete a customer, wait 30s, query `SELECT count(*) FROM iceberg.bronze.customers WHERE id = <customer_id> AND __op = 'd'` — print `[PASS]` or `[FAIL]`
- [x] 11.6 Ensure `validate.sh` exits 0 only if all checks PASS, exits 1 otherwise
