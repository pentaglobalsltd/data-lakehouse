-- Create extra databases for Hive Metastore and Airflow
-- Runs once on first Postgres container initialization (alongside 01_init.sql)

SELECT 'CREATE DATABASE metastore' WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = 'metastore'
)\gexec

SELECT 'CREATE DATABASE airflow' WHERE NOT EXISTS (
  SELECT FROM pg_database WHERE datname = 'airflow'
)\gexec
