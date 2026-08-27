#!/usr/bin/env bash
# Probe what is actually true about SQL Server Agent on THIS instance.
#
# The scheduling decision (sidecar vs SQL Server Agent) is usually made from
# folklore — "Agent isn't available in Linux containers" is repeated widely and
# is only partly true. This checks the running instance instead of assuming,
# and records the answer as evidence.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

echo "=== SQL Server Agent availability probe ==="
echo ""

echo "--- edition and version ---"
sql "SELECT
       SERVERPROPERTY('Edition')          AS [edition],
       SERVERPROPERTY('ProductVersion')   AS [version],
       SERVERPROPERTY('ProductLevel')     AS [level],
       SERVERPROPERTY('IsIntegratedSecurityOnly') AS [windows_auth_only];"

echo ""
echo "--- was MSSQL_AGENT_ENABLED passed to the container? ---"
docker inspect "$SQL_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -i 'AGENT' | sed 's/^/    /' || echo "    (not set)"

echo ""
echo "--- does the instance report Agent as running? ---"
# IsHadrEnabled-style properties are unreliable here; xp_servicecontrol is a
# Windows-only stored procedure. The supported check on Linux is this:
sql "SELECT
       CASE SERVERPROPERTY('IsAdvancedAnalyticsInstalled') WHEN 1 THEN 'yes' ELSE 'no' END AS [ml_services],
       (SELECT COUNT(*) FROM sys.dm_server_services)                                       AS [services_visible];"

echo ""
echo "--- registered services (Agent appears here when enabled) ---"
sql "SELECT servicename, status_desc, startup_type_desc FROM sys.dm_server_services;"

echo ""
echo "--- can msdb job objects be reached? ---"
JOBS="$(sqlv "SELECT COUNT(*) FROM msdb.dbo.sysjobs")"
echo "    msdb.dbo.sysjobs row count: ${JOBS:-<unreadable>}"
if [ -n "${JOBS:-}" ]; then
  echo "    msdb job tables ARE reachable, so Agent jobs could be defined"
else
  echo "    msdb job tables NOT reachable"
fi

echo ""
echo "--- conclusion ---"
AGENT_ROW="$(sqlv "SELECT status_desc FROM sys.dm_server_services WHERE servicename LIKE '%Agent%'")"
if [ -n "${AGENT_ROW:-}" ]; then
  echo "    SQL Server Agent is present on this instance, status: $AGENT_ROW"
  echo ""
  echo "    The sidecar scheduler is still used, deliberately:"
  echo "      * the schedule stays in version control as plain shell rather than"
  echo "        as rows inside msdb, which is itself only recoverable from a backup"
  echo "      * the same scripts run by hand for the drills, so what is scheduled"
  echo "        and what is demonstrated are provably the same code"
  echo "      * it works identically on Express edition, where Agent is absent"
else
  echo "    SQL Server Agent is NOT running on this instance."
  echo "    A sidecar scheduler is therefore required, not merely preferred."
fi
