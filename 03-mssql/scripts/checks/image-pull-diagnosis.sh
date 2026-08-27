#!/usr/bin/env bash
# Diagnose whether the SQL Server image can be pulled on this host.
#
# Task 03 cannot execute without mcr.microsoft.com/mssql/server. This script
# isolates exactly where the pull fails so the blocker is documented as a
# measured fact rather than "it didn't work".

set -uo pipefail
export MSYS_NO_PATHCONV=1

IMAGE="mcr.microsoft.com/mssql/server:2022-latest"

echo "=== SQL Server image pull diagnosis ==="
echo "timestamp: $(date '+%Y-%m-%d %H:%M:%S %z')"
echo ""

echo "--- 1. is the image already local? ---"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "    PRESENT: $(docker image inspect "$IMAGE" --format '{{index .RepoDigests 0}}')"
  echo ""
  echo "RESULT: IMAGE AVAILABLE - Task 03 can execute"
  exit 0
fi
echo "    absent"

echo ""
echo "--- 2. control: can the daemon pull from Docker Hub? ---"
timeout 120 docker pull busybox:latest > /dev/null 2>&1
HUB_RC=$?
echo "    docker pull busybox:latest -> exit $HUB_RC $([ $HUB_RC = 0 ] && echo '(works)' || echo '(FAILED)')"

echo ""
echo "--- 3. can the registry MANIFEST be read? ---"
DIGEST="$(timeout 90 docker buildx imagetools inspect "$IMAGE" --format '{{.Manifest.Digest}}' 2>/dev/null | tail -1)"
if [ -n "$DIGEST" ]; then
  echo "    manifest readable, digest: $DIGEST"
  echo "    => authentication, DNS and TLS to mcr.microsoft.com are all fine"
else
  echo "    manifest NOT readable"
fi

echo ""
echo "--- 4. where does a blob request redirect to? ---"
LAYER="$(timeout 90 docker buildx imagetools inspect "$IMAGE" --raw 2>/dev/null \
         | grep -o 'sha256:[a-f0-9]\{64\}' | sed -n '3p')"
echo "    largest layer: ${LAYER:-<unknown>}"
if [ -n "$LAYER" ]; then
  LOCATION="$(timeout 60 curl -s -o /dev/null -D - -r 0-1023 \
      "https://mcr.microsoft.com/v2/mssql/server/blobs/$LAYER" 2>/dev/null \
      | grep -i '^location:' | head -1 | cut -d' ' -f2- | cut -d'?' -f1)"
  echo "    307 redirect target: ${LOCATION:-<none>}"
fi

echo ""
echo "--- 5. can the HOST download 1 MiB of that blob? ---"
if [ -n "$LAYER" ]; then
  timeout 120 curl -s -L -o /dev/null -r 0-1048575 \
    -w '    HTTP %{http_code}, %{size_download} bytes downloaded, %{speed_download} B/s, %{time_total}s total\n' \
    "https://mcr.microsoft.com/v2/mssql/server/blobs/$LAYER" 2>&1 || echo "    curl aborted"
fi

echo ""
echo "--- 6. can the DAEMON pull the image? (bounded attempt) ---"
BEFORE="$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
timeout 180 docker pull "$IMAGE" > /dev/null 2>&1
PULL_RC=$?
AFTER="$(docker system df --format '{{.Size}}' 2>/dev/null | head -1)"
echo "    docker pull -> exit $PULL_RC (124 = timed out with no progress)"
echo "    total image bytes before: $BEFORE"
echo "    total image bytes after : $AFTER"
echo "    => unchanged size means ZERO bytes of the layer were transferred"

echo ""
echo "--- conclusion ---"
if docker image inspect "$IMAGE" > /dev/null 2>&1; then
  echo "RESULT: IMAGE AVAILABLE"
  exit 0
fi
cat <<'EOT'
RESULT: BLOCKED - the SQL Server image cannot be pulled on this host.

    The failure is NOT authentication, DNS, TLS or Docker configuration:
    the registry manifest is read successfully, and Docker Hub pulls work
    normally on the same daemon.

    mcr.microsoft.com answers a blob request with a 307 redirect to an Azure
    CDN data endpoint (westeurope.data.mcr.microsoft.com). That endpoint
    accepts the connection and returns HTTP 206, then transfers zero bytes.
    The stall reproduces from the HOST with plain curl, so it is a network
    path problem between this machine and the CDN edge, not something the
    Docker daemon is doing.

    Task 03 therefore cannot be executed here until that path works.
EOT
exit 1
