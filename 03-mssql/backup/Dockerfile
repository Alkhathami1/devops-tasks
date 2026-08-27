# The backup sidecar reuses the SQL Server image purely because it already
# contains mssql-tools18 (sqlcmd). Building on it avoids pulling a second
# ~1.5 GB image for the sake of one binary, and guarantees the client version
# matches the server exactly.
FROM mcr.microsoft.com/mssql/server:2022-latest@sha256:ba4c8329f48fb8f02e1416be6a930ebfd71268caee78aa985f3af4315e457c89

USER root
COPY lib.sh backup.sh retention.sh scheduler.sh /opt/backup/
RUN chmod 0755 /opt/backup/*.sh && mkdir -p /backups && chown -R mssql:root /backups /opt/backup

USER mssql
WORKDIR /opt/backup

# The scheduler is PID 1 so it receives SIGTERM directly and can shut down
# without waiting out the 10 second kill timeout.
ENTRYPOINT ["/opt/backup/scheduler.sh"]
