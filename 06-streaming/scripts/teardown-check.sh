#!/usr/bin/env bash
# After destroy: confirm nothing MediaLive-related survives, and that nothing
# is still running.
#
# The distinction that matters here is different from Task 05's orphan check:
#
#   a channel left RUNNING keeps transcoding indefinitely, and that is the
#     state worth catching
#   a channel that exists but is IDLE is a different condition: present, not
#     working. Only destroying it removes the resource entirely
#
# So this checks both existence AND state, and reports them separately.
set -uo pipefail
export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"; export AWS_PAGER=""
unset MSYS_NO_PATHCONV
REGION="${AWS_REGION:-eu-central-1}"

FOUND=0
RUNNING=0

echo "=== Post-destroy check: region $REGION ==="
echo ""

echo "--- MediaLive channels ---"
CH="$(aws medialive list-channels --region "$REGION" --query 'Channels[].[Id,Name,State]' --output text 2>/dev/null)"
if [ -z "$CH" ]; then
  echo "  [CLEAN]   no channels"
else
  echo "$CH" | sed 's/^/  [EXISTS] /'
  FOUND=$((FOUND + $(echo "$CH" | grep -c .)))
  RUNSTATE="$(echo "$CH" | grep -c RUNNING || true)"
  if [ "${RUNSTATE:-0}" -gt 0 ]; then
    echo "  [RUNNING] ${RUNSTATE} channel(s) are RUNNING right now"
    RUNNING=$((RUNNING + RUNSTATE))
  else
    echo "  (none RUNNING - any channel present is IDLE)"
  fi
fi

echo ""
echo "--- MediaLive inputs ---"
IN="$(aws medialive list-inputs --region "$REGION" --query 'Inputs[].[Id,Name,State]' --output text 2>/dev/null)"
[ -z "$IN" ] && echo "  [CLEAN]   no inputs" || { echo "$IN" | sed 's/^/  [EXISTS] /'; FOUND=$((FOUND+$(echo "$IN"|grep -c .))); }

echo ""
echo "--- MediaLive input security groups ---"
SG="$(aws medialive list-input-security-groups --region "$REGION" --query 'InputSecurityGroups[].[Id,State]' --output text 2>/dev/null)"
[ -z "$SG" ] && echo "  [CLEAN]   none" || { echo "$SG" | sed 's/^/  [EXISTS] /'; FOUND=$((FOUND+$(echo "$SG"|grep -c .))); }

echo ""
echo "--- S3 buckets matching task06 ---"
BK="$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'task06')].Name" --output text 2>/dev/null)"
if [ -z "$BK" ] || [ "$BK" = "None" ]; then
  echo "  [CLEAN]   no task06 buckets"
else
  for b in $BK; do
    N="$(aws s3api list-objects-v2 --bucket "$b" --query 'length(Contents)' --output text 2>/dev/null)"
    [ "$N" = "None" ] && N=0
    echo "  [EXISTS]  $b  (${N} objects)"
    FOUND=$((FOUND + 1))
  done
fi

echo ""
echo "--- IAM roles matching task06 ---"
RL="$(aws iam list-roles --query "Roles[?starts_with(RoleName,'task06')].RoleName" --output text 2>/dev/null)"
[ -z "$RL" ] || [ "$RL" = "None" ] && echo "  [CLEAN]   none" || { echo "$RL" | tr '\t' '\n' | sed 's/^/  [EXISTS] /'; }

echo ""
echo "================================================================"
if [ "$RUNNING" -gt 0 ]; then
  echo "RESULT: ${RUNNING} CHANNEL(S) STILL RUNNING. Stop them."
  exit 2
elif [ "$FOUND" -gt 0 ]; then
  echo "RESULT: ${FOUND} resource(s) remain, none RUNNING."
  exit 1
else
  echo "RESULT: CLEAN — nothing remains, nothing left running"
  exit 0
fi
