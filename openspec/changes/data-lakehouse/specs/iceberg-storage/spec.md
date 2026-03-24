## ADDED Requirements

### Requirement: MinIO bucket and credentials
MinIO SHALL start with access key `minioadmin` and secret key `minioadmin123`. A bucket named `lakehouse` SHALL be created at startup (via mc or init container). MinIO console SHALL be accessible at port 9001 and S3 API at port 9000.

#### Scenario: MinIO bucket exists after startup
- **WHEN** MinIO container is healthy
- **THEN** `mc ls minio/lakehouse` returns successfully (bucket exists)

#### Scenario: S3 path-style access works
- **WHEN** an S3 client issues `GET http://minio:9000/lakehouse/`
- **THEN** a 200 or 204 response is returned (path-style addressing works)

### Requirement: Iceberg REST catalog operational
An Iceberg REST catalog SHALL run at `http://iceberg-rest:8181` with warehouse path `s3://lakehouse/` backed by MinIO. The catalog SHALL persist table metadata as Iceberg JSON metadata files in MinIO (not in-memory only).

#### Scenario: REST catalog health check passes
- **WHEN** `GET http://iceberg-rest:8181/v1/config` is called
- **THEN** a 200 response is returned with Iceberg REST catalog configuration

#### Scenario: Namespace `bronze` exists after Flink job starts
- **WHEN** the Flink job has started and performed its first checkpoint
- **THEN** `GET http://iceberg-rest:8181/v1/namespaces` includes `bronze`

### Requirement: Bronze Iceberg tables created by Flink job
The Flink job SHALL auto-create three Iceberg tables in the `bronze` namespace: `bronze.customers`, `bronze.products`, and `bronze.orders`. Each table SHALL include an `__op` column of type STRING. All tables SHALL be partitioned by `date(created_at)`.

#### Scenario: Bronze tables queryable via Trino
- **WHEN** Trino queries `SELECT count(*) FROM iceberg.bronze.orders`
- **THEN** a numeric result is returned without error

#### Scenario: Bronze customers table schema includes __op
- **WHEN** `DESCRIBE iceberg.bronze.customers` is run in Trino
- **THEN** the result includes a column named `__op` of type `varchar`

### Requirement: Silver and gold layers as Trino views
Silver layer views SHALL deduplicate bronze data (keep latest by `updated_at`) and cast types. Gold layer views SHALL join silver tables into business-level aggregations. Views SHALL be created in the `silver` and `gold` schemas of the `iceberg` catalog.

#### Scenario: Silver orders view returns deduplicated rows
- **WHEN** `SELECT count(*) FROM iceberg.silver.orders` is run
- **THEN** each `id` appears at most once in the result

#### Scenario: Gold orders summary view is queryable
- **WHEN** `SELECT * FROM iceberg.gold.order_summary LIMIT 5` is run
- **THEN** results are returned without error and include customer and product information
