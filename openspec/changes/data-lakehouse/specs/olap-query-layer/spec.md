## ADDED Requirements

### Requirement: Trino configured with iceberg and clickhouse catalogs
Trino 438 SHALL be configured with an `iceberg` catalog pointing to the Iceberg REST catalog at `http://iceberg-rest:8181` and a `clickhouse` catalog pointing to ClickHouse at `http://clickhouse:8123`. Both catalogs SHALL be accessible via Trino SQL.

#### Scenario: Trino iceberg catalog is queryable
- **WHEN** `SHOW SCHEMAS FROM iceberg` is run against Trino
- **THEN** `bronze`, `silver`, and `gold` are listed

#### Scenario: Trino clickhouse catalog is queryable
- **WHEN** `SHOW SCHEMAS FROM clickhouse` is run against Trino
- **THEN** at least the `default` schema is listed

#### Scenario: Trino can query across both catalogs in one query
- **WHEN** a federated query joining `iceberg.bronze.orders` and `clickhouse.default.order_agg` is executed
- **THEN** the query completes without error

### Requirement: ClickHouse configured and accessible
ClickHouse 24.3 SHALL expose HTTP port 8123 and native TCP port 9000 (host-mapped to 19000 to avoid MinIO conflict). A database `default` SHALL exist. ClickHouse SHALL have an `order_agg` table with aggregated order totals by city.

#### Scenario: ClickHouse HTTP interface responds
- **WHEN** `GET http://clickhouse:8123/?query=SELECT+1` is called
- **THEN** response body is `1\n` with HTTP 200

#### Scenario: order_agg table exists with data
- **WHEN** `SELECT count(*) FROM default.order_agg` is run via ClickHouse HTTP
- **THEN** a non-zero count is returned

### Requirement: ClickHouse order_agg table populated from Iceberg
A ClickHouse table `default.order_agg` SHALL be created and populated with aggregated order data: total revenue, order count, and average order value grouped by customer city. This population SHALL occur as part of bootstrap after Iceberg bronze tables are seeded.

#### Scenario: order_agg contains per-city aggregations
- **WHEN** `SELECT city, total_revenue, order_count FROM default.order_agg ORDER BY order_count DESC LIMIT 5` is run
- **THEN** at least 3 distinct cities are present with non-zero `total_revenue`
