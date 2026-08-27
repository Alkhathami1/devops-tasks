#!/usr/bin/env bash
# Strip anything account-identifying from a stream on its way into an evidence
# log. THIS REPOSITORY IS PUBLIC.
#
#   some-command | scripts/redact.sh
#   scripts/redact.sh < file > file.redacted
#
# TWO MODES
# ---------
#   full      (default) everything below, including a blanket rule that masks
#             any bare 12-digit number as a possible AWS account id.
#   identity  everything except the blanket 12-digit rule.
#
# The distinction exists because the blanket rule is destructive to legitimate
# output: disk byte counts, sha256 fragments and provider-lock hashes are full
# of 12-digit runs, and masking them turns a useful log into a puzzle. That is
# why scripts/run-with-evidence.sh runs this in `identity` mode - safe enough to
# apply to every capture without corrupting the evidence it is protecting.
#
#   REDACT_MODE=identity scripts/redact.sh
#
# What it removes and why:
#
#   12-digit account ids   (full mode only) an AWS account id is not a secret
#                          the way a key is, but it is an identifier an attacker
#                          can use for targeted phishing, S3 bucket enumeration
#                          and cross-account role guessing.
#   ARNs                   embed the account id in the 5th field.
#   access key ids         AKIA/ASIA prefixes.
#   secret access keys     40-char base64-ish strings following a key-ish label.
#   session tokens         long FQoG.../IQoJ... blobs.
#   presigned URL params   X-Amz-Signature / X-Amz-Credential.
#   MediaLive endpoints    the RTP push endpoint is an open ingest target for
#                          as long as the channel exists.
#   GCP billing account    billingAccounts/XXXXXX-XXXXXX-XXXXXX names the payer,
#                          not just the project, and is a phishing lever.
#   GCP project number     the numeric twin of the project id.
#   personal emails        addresses belonging to a person. Service-account
#                          addresses (*.gserviceaccount.com) are deliberately
#                          KEPT: they name infrastructure, have no inbox, and
#                          removing them would make the IAM evidence unreadable.
#
# The GCP rules and the wiring into the capture path were both added after the
# fact. An early preflight log published a billing account id and a work email
# because this redactor knew one cloud, the repository used two, and nothing
# forced the capture through it. A filter that is not wired into the thing that
# writes evidence protects nothing.
#
# Identifiers are read from the environment rather than hardcoded, so this file
# itself carries none.

set -uo pipefail

MODE="${REDACT_MODE:-full}"
ACCT="${AWS_ACCOUNT_ID:-}"
GCPNUM="${GCP_PROJECT_NUMBER:-}"

# These two mask identifiers that only exist at capture time. Unset, they are a
# silent no-op, and the failure mode is publishing the identifier - so say so.
[ -z "$ACCT" ]   && echo "redact.sh: AWS_ACCOUNT_ID unset, account-id masking inactive" >&2
[ -z "$GCPNUM" ] && echo "redact.sh: GCP_PROJECT_NUMBER unset, project-number masking inactive" >&2

ARGS=(
  # Key material first. Every rule below is a separate sed expression applied
  # in order, so a later rule that rewrites digits inside a base64 run breaks
  # the match this one needs and leaves most of the key in the log - which is
  # exactly what the blanket 12-digit rule does to a key containing twelve
  # consecutive digits. Masking the key material before anything else touches
  # the stream removes the interaction rather than relying on luck.
  #
  # `wg show` prints `private key: (hidden)`, but a config read with cat does
  # not. Curve25519 keys are 44 base64 characters; the public halves carry a
  # different label and are deliberately left alone.
  -e 's/(AKIA|ASIA)[0-9A-Z]{16}/<AWS-ACCESS-KEY-ID>/g'
  -e 's#(PrivateKey|PresharedKey)([[:space:]]*=[[:space:]]*)[A-Za-z0-9+/]{43}=#\1\2<REDACTED>#g'
  -e 's#(private key:[[:space:]]*)[A-Za-z0-9+/]{43}=#\1<REDACTED>#g'
  -e 's/(aws_secret_access_key|SecretAccessKey|secret_key)([[:space:]]*[:=][[:space:]]*)["'"'"']?[A-Za-z0-9\/+=]{40}["'"'"']?/\1\2<REDACTED>/gI'
  -e 's/(aws_session_token|SessionToken)([[:space:]]*[:=][[:space:]]*)["'"'"']?[A-Za-z0-9\/+=_-]{100,}["'"'"']?/\1\2<REDACTED>/gI'
)
[ "$MODE" = "full" ] && ARGS+=(-e 's/[0-9]{12}/<ACCOUNT-ID>/g')

ARGS+=(
  -e 's#arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:#arn:aws:<SERVICE>:<REGION>:<ACCOUNT-ID>:#g'
  -e 's#arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:<ACCOUNT-ID>:#arn:aws:<SERVICE>:<REGION>:<ACCOUNT-ID>:#g'
  -e 's/(X-Amz-Signature=)[a-f0-9]+/\1<REDACTED>/g'
  -e 's/(X-Amz-Credential=)[^&[:space:]]+/\1<REDACTED>/g'
  -e 's#rtp://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+#rtp://<MEDIALIVE-INGEST-ENDPOINT>#g'
  -e 's#srt://[0-9]{1,3}(\.[0-9]{1,3}){3}:[0-9]+#srt://<MEDIALIVE-INGEST-ENDPOINT>#g'
  # A routable address pinned into a log outlives the resource that held it:
  # an ephemeral address returns to the provider's pool and belongs to someone
  # else. Private, loopback and link-local ranges carry the meaning in a
  # topology, so they are parked behind a sentinel, every remaining dotted quad
  # is masked, and the sentinel is removed. These three must stay in this order.
  -e 's/\b(10\.|127\.|192\.168\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[01])\.)/__PRIVIP__\1/g'
  -e 's/\b[0-9]{1,3}(\.[0-9]{1,3}){3}\b/<PUBLIC-IP>/g'
  -e 's/__PRIVIP__//g'
  -e 's#billingAccounts/[0-9A-Za-z]{6}-[0-9A-Za-z]{6}-[0-9A-Za-z]{6}#billingAccounts/<BILLING-ACCOUNT>#g'
  # sed -E has no negative lookahead, so service-account addresses are parked
  # behind a sentinel, every remaining address is redacted, and the sentinel is
  # restored. These three must stay adjacent and in this order.
  -e 's/@([A-Za-z0-9.-]*gserviceaccount\.com)/__AT_SVCACCT__\1/g'
  -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/<REDACTED-EMAIL>/g'
  -e 's/__AT_SVCACCT__/@/g'
)

[ -n "$ACCT" ]   && ARGS+=(-e "s/${ACCT}/<ACCOUNT-ID>/g")
[ -n "$GCPNUM" ] && ARGS+=(-e "s/${GCPNUM}/<GCP-PROJECT-NUMBER>/g")

sed -E "${ARGS[@]}"
