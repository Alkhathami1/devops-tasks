#!/usr/bin/env bash
# SECRETS — file-based Docker secret vs environment variable, side by side.
#
# The assignment allows "a secret manager OR environment variables". Both are
# used here, for different classes of data, and this script demonstrates WHY the
# split exists rather than asserting it.
#
# The contrast: a value passed via `-e` is stored in the container's config and
# is readable by anyone who can reach the Docker socket, forever, without
# entering the container. A file-based secret is a tmpfs mount whose contents
# never appear in the container's metadata.
#
# SAFETY: the demonstration container uses an obviously fake password. The real
# secret is never printed by this script.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$STACK_DIR"
export MSYS_NO_PATHCONV=1

DEMO_PASSWORD="DEMO-FAKE-PASSWORD-not-the-real-one-3f9a2c"
DEMO_NAME="task02-secret-demo"

RESULT=0
pass() { echo "[PASS] $*"; }
fail() { echo "[FAIL] $*"; RESULT=1; }

cleanup() { docker rm -f "$DEMO_NAME" > /dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

echo "=== SECRETS: environment variable vs file-based secret ==="
echo ""

# ---------------------------------------------------------------------------
echo "############################################################"
echo "# 1. THE WRONG WAY: password in an environment variable"
echo "############################################################"
echo ""
echo "--- starting a container with -e PASSWORD=<value> ---"
docker run -d --name "$DEMO_NAME" \
  -e "POSTGRES_PASSWORD=$DEMO_PASSWORD" \
  -e "APP_NAME=demo" \
  alpine:latest sleep 300 > /dev/null 2>&1

echo ""
echo "--- docker inspect on that container (Env array) ---"
LEAKED=$(docker inspect "$DEMO_NAME" --format '{{range .Config.Env}}    {{println .}}{{end}}')
echo "$LEAKED"

echo "$LEAKED" | grep -q "$DEMO_PASSWORD" \
  && pass "the password IS visible in docker inspect, in plain text" \
  || fail "expected the env var to leak but it did not"

echo ""
echo "--- it also leaks to every process in the container ---"
echo "    /proc/1/environ:"
docker exec "$DEMO_NAME" cat /proc/1/environ 2>/dev/null | tr '\0' '\n' | sed 's/^/      /' | grep -i 'password\|app_name' || true

echo ""
echo "    Anyone with access to the Docker socket can read this without entering"
echo "    the container, without any credential of their own, at any time while"
echo "    the container exists. It is also inherited by every child process and"
echo "    is commonly captured by crash reporters and process listings."

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# 2. THE RIGHT WAY: file-based Docker secret"
echo "############################################################"
echo ""
echo "--- docker inspect on the REAL postgres container (Env array) ---"
REAL_ENV=$(docker inspect task02-postgres --format '{{range .Config.Env}}    {{println .}}{{end}}')
echo "$REAL_ENV"

REAL_SECRET=$(cat secrets/postgres_password.txt)

echo "$REAL_ENV" | grep -q "$REAL_SECRET" \
  && fail "the real password leaked into the environment" \
  || pass "the real password does NOT appear anywhere in docker inspect"

echo "$REAL_ENV" | grep -q 'POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password' \
  && pass "only a PATH is exposed, not a value" \
  || fail "expected POSTGRES_PASSWORD_FILE to be present"

echo ""
echo "--- where the value actually lives ---"
echo "    mount type and target inside the container:"
docker inspect task02-postgres --format '{{range .Mounts}}{{if eq .Destination "/run/secrets/postgres_password"}}      type={{.Type}} destination={{.Destination}} rw={{.RW}}{{end}}{{end}}'
echo "    file mode inside the container:"
docker exec task02-postgres stat -c '      %A %U:%G %n (%s bytes)' /run/secrets/postgres_password 2>/dev/null || true

echo ""
echo "    The value is not in the container's config, so it is not in"
echo "    'docker inspect', not in the image, and not in any registry layer."
echo ""
echo "    HONEST LIMITATION: note 'type=bind' above. Compose (outside Swarm)"
echo "    implements file-based secrets as a BIND MOUNT of a host file, not as"
echo "    the in-memory tmpfs that Swarm/Kubernetes secrets use. Consequences:"
echo "      - the plaintext exists on the host disk at secrets/postgres_password.txt"
echo "      - the mode shown (777 here) is an artefact of the Windows/WSL bind"
echo "        mount, not a permission the file really carries on an ext4 host"
echo "      - it is still strictly better than an env var, because it stays out"
echo "        of container metadata, out of child process environments and out"
echo "        of crash dumps"
echo "      - for production, the host file should be sourced from a real secret"
echo "        manager (Vault, AWS Secrets Manager, SOPS-encrypted at rest) rather"
echo "        than generated and left on disk"

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# 3. FULL-CONFIG SWEEP: is the real secret anywhere it should not be?"
echo "############################################################"
echo ""
for container in task02-postgres task02-backend task02-nginx; do
  FULL=$(docker inspect "$container" 2>/dev/null)
  if echo "$FULL" | grep -q "$REAL_SECRET"; then
    fail "$container: real password found in inspect output"
  else
    pass "$container: real password absent from the ENTIRE inspect output"
  fi
done

echo ""
echo "--- and not in the images either ---"
for image in task02-backend:1.0.0 task02-nginx:1.0.0; do
  if docker image inspect "$image" 2>/dev/null | grep -q "$REAL_SECRET"; then
    fail "$image: real password baked into the image"
  else
    pass "$image: real password absent from image metadata"
  fi
done

echo ""
echo "--- and not committed to git ---"
# Run git from the repo root in a subshell. `git -C <posix path>` fails here:
# MSYS_NO_PATHCONV=1 (needed for container-side paths) stops Git Bash rewriting
# the path, and git.exe is a native Windows binary that cannot chdir to /c/...
if ( cd "$STACK_DIR/.." && git check-ignore -q 02-docker-stack/secrets/postgres_password.txt ); then
  pass "secrets/postgres_password.txt is gitignored"
else
  fail "the secret file is NOT gitignored"
fi

if ( cd "$STACK_DIR/.." && git ls-files --error-unmatch 02-docker-stack/secrets/postgres_password.txt > /dev/null 2>&1 ); then
  fail "the secret file is TRACKED by git"
else
  pass "the secret file is not tracked by git"
fi

# ---------------------------------------------------------------------------
echo ""
echo "############################################################"
echo "# 4. WHAT ENVIRONMENT VARIABLES ARE STILL USED FOR"
echo "############################################################"
echo ""
echo "    Non-sensitive configuration stays in .env, because the operational"
echo "    convenience is real and the exposure costs nothing:"
docker inspect task02-backend --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | grep -E '^(POSTGRES_DB|POSTGRES_USER|POSTGRES_HOST|POSTGRES_PORT|NODE_ENV|PORT|PG_POOL_MAX)=' \
  | sed 's/^/      /'
echo ""
echo "    A database name and role are visible in any connection error message"
echo "    anyway. A password is not, and must not be."

echo ""
[ "$RESULT" = "0" ] && echo "RESULT: SECRETS COMPARISON PASSED" || echo "RESULT: $RESULT CHECK(S) FAILED"
exit "$RESULT"
