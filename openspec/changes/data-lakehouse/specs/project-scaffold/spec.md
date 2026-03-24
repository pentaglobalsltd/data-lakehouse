## ADDED Requirements

### Requirement: Docker Compose project with all services on lakehouse network
A `docker-compose.yml` SHALL define all services on a single Docker bridge network named `lakehouse`. Services SHALL include: `postgres`, `zookeeper`, `kafka`, `kafka-connect`, `iceberg-rest`, `minio`, `minio-init`, `flink-jobmanager`, `flink-taskmanager`, `trino`, `clickhouse`, and `superset`.

#### Scenario: All services start with docker compose up -d
- **WHEN** `docker compose up -d` is run in `lakehouse-poc/`
- **THEN** all containers reach status `running` or `healthy` within 5 minutes

#### Scenario: All services share the lakehouse network
- **WHEN** `docker network inspect lakehouse` is run
- **THEN** all 12+ service containers are listed as members

### Requirement: bootstrap.sh installs dependencies and starts pipeline end-to-end
`scripts/bootstrap.sh` SHALL, on a fresh Ubuntu 22.04 VM: install Docker Engine + Compose plugin, install OpenJDK 11 + Maven 3.8, start all services, wait for each to be healthy, register the Debezium connector, build the Flink fat JAR, and submit it to Flink JobManager. The script SHALL exit non-zero if any step fails.

#### Scenario: Bootstrap succeeds on fresh Ubuntu 22.04
- **WHEN** `bash scripts/bootstrap.sh` is run on a system without Docker or Java
- **THEN** the script exits 0 and all services are running with the Flink job in RUNNING state

#### Scenario: Bootstrap waits for service health before proceeding
- **WHEN** bootstrap.sh starts Kafka
- **THEN** it polls Kafka's port until available before starting Kafka Connect

### Requirement: validate.sh performs end-to-end pipeline validation
`scripts/validate.sh` SHALL: insert a new order into PostgreSQL, wait 30 seconds, query Trino for the new row in `iceberg.bronze.orders`, query ClickHouse for aggregated data, print PASS/FAIL for each check, update the order status and re-validate, delete a customer and confirm `__op=d` tombstone in Iceberg. The script SHALL exit 0 only if all checks PASS.

#### Scenario: INSERT check passes
- **WHEN** validate.sh inserts an order and waits 30 seconds
- **THEN** the Trino check prints `[PASS] New order found in iceberg.bronze.orders`

#### Scenario: UPDATE check passes
- **WHEN** validate.sh updates the order status
- **THEN** the Trino check prints `[PASS] Updated order status reflected in iceberg.bronze.orders`

#### Scenario: DELETE tombstone check passes
- **WHEN** validate.sh deletes a customer
- **THEN** the Trino check prints `[PASS] Delete tombstone (__op=d) found in iceberg.bronze.customers`

#### Scenario: ClickHouse aggregation check passes
- **WHEN** validate.sh queries ClickHouse after data propagation
- **THEN** the check prints `[PASS] ClickHouse order_agg contains data`

### Requirement: Directory structure matches specification
The `lakehouse-poc/` directory SHALL contain all required files: `docker-compose.yml`, `postgres-init/01_init.sql`, `kafka-connect/debezium-connector.json`, `trino/config.properties`, `trino/catalog/iceberg.properties`, `trino/catalog/clickhouse.properties`, `clickhouse/config.xml`, `superset/superset_config.py`, `flink-jobs/pom.xml`, `flink-jobs/src/main/java/com/lakehouse/KafkaToIcebergJob.java`, `scripts/bootstrap.sh`, `scripts/register-connector.sh`, and `scripts/validate.sh`.

#### Scenario: All required files are present
- **WHEN** `find lakehouse-poc/ -type f` is run
- **THEN** all 13 required files are listed in the output
