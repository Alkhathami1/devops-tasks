# SQL Server 2022, pinned by tag AND digest so a rebuild resolves the identical
# base image rather than whatever "2022-latest" points at that week.
FROM mcr.microsoft.com/mssql/server:2022-latest@sha256:ba4c8329f48fb8f02e1416be6a930ebfd71268caee78aa985f3af4315e457c89

# The entrypoint wrapper reads the SA password from a mounted Docker secret and
# exports it only into the sqlservr process, so the password never appears in
# the container's compose configuration or in `docker inspect`.
USER root
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

# Back to the unprivileged account the base image runs as (mssql, uid 10001).
# The data directory must be owned by this user, which is exactly why a named
# volume is used rather than a Windows bind mount - see compose.yaml.
USER mssql

# A healthcheck that only probes the TCP port reports healthy while the engine
# is still recovering databases and cannot answer a query. This runs a real
# SELECT 1 through sqlcmd instead.
#   -C  trust the self-signed certificate (mssql-tools18 encrypts by default)
#   -l  connection timeout, so a hung probe fails rather than blocking
HEALTHCHECK --interval=10s --timeout=10s --start-period=90s --retries=10 \
  CMD /opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P "$(cat /run/secrets/mssql_sa_password)" \
      -C -l 5 -Q "SELECT 1" > /dev/null 2>&1 || exit 1

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/opt/mssql/bin/sqlservr"]
