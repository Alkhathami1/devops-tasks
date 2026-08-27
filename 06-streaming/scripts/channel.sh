#!/usr/bin/env bash
# MediaLive channel control, with the running clock made visible.
#
#   scripts/channel.sh start
#   scripts/channel.sh status
#   scripts/channel.sh stop
#   scripts/channel.sh endpoints
#
# WHY THIS IS ITS OWN SCRIPT, separate from terraform:
#
# A MediaLive channel has two distinct states. Created and IDLE, it exists and
# consumes nothing. RUNNING, it is transcoding whether or not anything is being
# pushed to its input — an idle feed and a live feed put it in exactly the same
# state.
#
# So `terraform apply` deliberately does NOT start the channel. Creating it and
# running it are separate decisions, so start and stop are explicit timestamped
# actions, and this script prints the elapsed running time on every invocation
# so a channel is never left running unnoticed.

set -uo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF="$STACK_DIR/terraform"
STAMP_FILE="$STACK_DIR/out/.channel-started"

export PATH="$PATH:/c/Program Files/Amazon/AWSCLIV2"
export AWS_PAGER=""
# aws.exe and terraform.exe are native binaries; a POSIX path passed with
# MSYS_NO_PATHCONV set is not converted and they fail confusingly.
unset MSYS_NO_PATHCONV

REGION="$(cd "$TF" && terraform output -raw region 2>/dev/null || echo eu-central-1)"
CHANNEL_ID="$(cd "$TF" && terraform output -raw channel_id 2>/dev/null)"

if [ -z "${CHANNEL_ID:-}" ]; then
  echo "ERROR: no channel_id in terraform output. Has apply run?" >&2
  exit 1
fi

state() {
  aws medialive describe-channel --channel-id "$CHANNEL_ID" --region "$REGION" \
    --query State --output text 2>/dev/null
}

elapsed_note() {
  [ -f "$STAMP_FILE" ] || return 0
  local start now sec min
  start="$(cat "$STAMP_FILE")"
  now="$(date +%s)"
  sec=$((now - start))
  min=$(( (sec + 59) / 60 ))
  echo "    running for ${sec}s (${min} minute(s))"
}

case "${1:-status}" in

  start)
    S="$(state)"
    if [ "$S" = "RUNNING" ]; then
      echo "channel already RUNNING"
      elapsed_note
      exit 0
    fi
    echo "=== STARTING channel — the running clock starts NOW ==="
    date -u '+started at %Y-%m-%dT%H:%M:%SZ'
    date +%s > "$STAMP_FILE"
    aws medialive start-channel --channel-id "$CHANNEL_ID" --region "$REGION" \
      --query 'State' --output text
    echo "waiting for RUNNING..."
    for i in $(seq 1 60); do
      S="$(state)"
      printf '\r    state: %-12s (%ds)' "$S" $((i * 5))
      [ "$S" = "RUNNING" ] && break
      sleep 5
    done
    echo ""
    [ "$(state)" = "RUNNING" ] && echo "channel is RUNNING" || echo "channel did not reach RUNNING: $(state)"
    elapsed_note
    ;;

  stop)
    echo "=== STOPPING channel ==="
    date -u '+stop requested at %Y-%m-%dT%H:%M:%SZ'
    elapsed_note
    aws medialive stop-channel --channel-id "$CHANNEL_ID" --region "$REGION" \
      --query 'State' --output text
    echo "waiting for IDLE..."
    for i in $(seq 1 60); do
      S="$(state)"
      printf '\r    state: %-12s (%ds)' "$S" $((i * 5))
      [ "$S" = "IDLE" ] && break
      sleep 5
    done
    echo ""
    FINAL="$(state)"
    echo "final state: $FINAL"
    if [ "$FINAL" = "IDLE" ]; then
      echo "Channel is IDLE. It exists and is no longer transcoding."
      date -u '+stopped at %Y-%m-%dT%H:%M:%SZ'
      [ -f "$STAMP_FILE" ] && mv "$STAMP_FILE" "${STAMP_FILE}.done"
    else
      echo "WARNING: channel is $FINAL, not IDLE. It may still be running."
    fi
    ;;

  status)
    echo "channel state: $(state)"
    elapsed_note
    ;;

  endpoints)
    # Printed for the operator; redacted on the way into any evidence log.
    aws medialive describe-input \
      --input-id "$(cd "$TF" && terraform output -raw input_id)" \
      --region "$REGION" --query 'Destinations[].Url' --output text
    ;;

  *)
    echo "usage: $0 {start|stop|status|endpoints}" >&2
    exit 2
    ;;
esac
