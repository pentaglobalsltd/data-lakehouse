import os

# ─── Core security ─────────────────────────────────────────────────────────
SECRET_KEY = os.environ.get("SUPERSET_SECRET_KEY", "lakehouse-poc-secret-key-change-in-production")

# ─── Database (SQLite for POC) ─────────────────────────────────────────────
SQLALCHEMY_DATABASE_URI = "sqlite:////app/superset_home/superset.db"

# ─── Session cookie ────────────────────────────────────────────────────────
SESSION_COOKIE_SAMESITE = "Lax"
SESSION_COOKIE_SECURE = False
SESSION_COOKIE_HTTPONLY = True

# ─── CSRF (disable for POC API usage in bootstrap.sh) ─────────────────────
WTF_CSRF_ENABLED = False

# ─── Feature flags ─────────────────────────────────────────────────────────
FEATURE_FLAGS = {
    "ENABLE_TEMPLATE_PROCESSING": True,
    "GLOBAL_ASYNC_QUERIES": False,
}

# ─── Datasource URIs (registered programmatically in bootstrap.sh) ─────────
# Trino:      trino://admin@trino:8080/iceberg
# ClickHouse: clickhouse+http://default:@clickhouse:8123/default

# ─── Logging ────────────────────────────────────────────────────────────────
import logging
LOG_LEVEL = logging.WARNING
