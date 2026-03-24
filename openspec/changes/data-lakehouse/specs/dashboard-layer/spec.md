## ADDED Requirements

### Requirement: Superset accessible with admin credentials
Apache Superset 3.1 SHALL be accessible at port 8088. The default admin credentials SHALL be `admin` / `admin`. Superset SHALL start with a pre-initialized database (Flask DB init + admin user creation handled at container start).

#### Scenario: Superset login page loads
- **WHEN** `GET http://superset:8088/login/` is called
- **THEN** HTTP 200 is returned and the page contains a login form

#### Scenario: Admin login succeeds
- **WHEN** a POST to Superset login with `admin`/`admin` credentials is made
- **THEN** a session cookie is set and the dashboard home page is reachable

### Requirement: Trino datasource pre-configured in Superset
A Superset database connection named `Trino - Lakehouse` SHALL be pre-configured pointing to `trino://trino@trino:8080/iceberg`. This datasource SHALL be available for building charts and datasets.

#### Scenario: Trino datasource visible in Superset
- **WHEN** an authenticated user navigates to Settings → Database Connections
- **THEN** a connection named `Trino - Lakehouse` is listed

#### Scenario: Trino datasource can execute a test query
- **WHEN** the `Trino - Lakehouse` connection test is run from Superset
- **THEN** the test returns a success result

### Requirement: ClickHouse datasource pre-configured in Superset
A Superset database connection named `ClickHouse - Lakehouse` SHALL be pre-configured using the ClickHouse SQLAlchemy URI `clickhouse+http://default:@clickhouse:8123/default`. This datasource SHALL be available for OLAP charts.

#### Scenario: ClickHouse datasource visible in Superset
- **WHEN** an authenticated user navigates to Settings → Database Connections
- **THEN** a connection named `ClickHouse - Lakehouse` is listed

#### Scenario: ClickHouse datasource can execute a test query
- **WHEN** the `ClickHouse - Lakehouse` connection test is run from Superset
- **THEN** the test returns a success result
