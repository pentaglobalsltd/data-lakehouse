FROM apache/hive:3.1.3
# Remove ancient bundled PostgreSQL JDBC driver (9.4.x) that references
# pg_am.amcanorder, which was removed in PostgreSQL 11. The 42.6.x driver
# bind-mounted at runtime is the correct one for PG 14+.
USER root
RUN rm -f /opt/hive/lib/postgresql-9.4.1208.jre7.jar
USER hive
