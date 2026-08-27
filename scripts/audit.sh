#!/usr/bin/env bash
# Repo-wide auditor. Re-derives claims instead of trusting them.
#
#   scripts/audit.sh
#
# Exits non-zero if ANY check fails. Designed to be run by someone who does not
# trust the report — every check reads the repository or the git object store
# rather than any summary written about it.
#
# Checks:
#   1. git hygiene        clean tree, local == remote
#   2. secret hygiene     nothing dangerous TRACKED, no credential patterns in content
#   3. evidence integrity BOM, no ANSI escapes, no mojibake, non-trivial size
#   4. report references  every evidence file REPORT.md cites actually exists
#   5. shipped documents  no placeholders, no internal review vocabulary

set -uo pipefail
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

FAILURES=0
CHECKS=0

pass() { CHECKS=$((CHECKS+1)); printf '[PASS] %s\n' "$*"; }
fail() { CHECKS=$((CHECKS+1)); FAILURES=$((FAILURES+1)); printf '[FAIL] %s\n' "$*"; }
info() { printf '       %s\n' "$*"; }
head2() { printf '\n--- %s ---\n' "$*"; }

echo "================================================================"
echo "REPOSITORY AUDIT"
echo "repo      : $REPO_ROOT"
echo "timestamp : $(date '+%Y-%m-%d %H:%M:%S %z')"
echo "================================================================"

# ---------------------------------------------------------------- 1. git ----
head2 "1. Git hygiene"

DIRTY="$(git status --porcelain | wc -l)"
if [ "$DIRTY" -eq 0 ]; then
  pass "working tree is clean"
else
  fail "working tree has $DIRTY uncommitted change(s)"
  git status --short | sed 's/^/       /'
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
LOCAL="$(git rev-parse HEAD)"
info "branch $BRANCH at $LOCAL"

# Prefer the gh API: `git ls-remote` needs credential-helper interactivity that
# a non-interactive shell does not have.
GH="/c/Program Files/GitHub CLI/gh.exe"
[ -x "$GH" ] || GH="$(command -v gh 2>/dev/null || true)"
REMOTE=""
if [ -n "$GH" ] && [ -x "$GH" ]; then
  SLUG="$(git remote get-url origin 2>/dev/null | sed -E 's#.*github.com[:/]##; s#\.git$##')"
  REMOTE="$("$GH" api "repos/$SLUG/commits/$BRANCH" --jq .sha 2>/dev/null || true)"
fi

if [ -z "$REMOTE" ]; then
  fail "could not determine the remote HEAD (gh unavailable or unauthenticated)"
elif [ "$LOCAL" = "$REMOTE" ]; then
  pass "local HEAD matches remote ($REMOTE)"
else
  fail "local $LOCAL != remote $REMOTE - unpushed or diverged"
fi

# ------------------------------------------------------------- 2. secrets ---
head2 "2. Secret hygiene"

# Only TRACKED files matter. An ignored .env on disk is fine; a committed one
# is not, so this asks git what is in the index rather than what is on disk.
BAD_TRACKED=0
while IFS= read -r pattern; do
  HITS="$(git ls-files | grep -E "$pattern" || true)"
  if [ -n "$HITS" ]; then
    fail "tracked files match forbidden pattern: $pattern"
    echo "$HITS" | sed 's/^/       /'
    BAD_TRACKED=1
  fi
done <<'PATTERNS'
(^|/)node_modules/
(^|/)\.env$
\.env\.(local|production)$
(^|/)secrets/[^/]*\.txt$
\.pem$
\.key$
(^|/)id_rsa
\.tfstate($|\.)
(^|/)\.terraform/
(^|/)terraform\.tfvars$
(^|/)\.ssh/(?!.*\.pub$)[^/]*$
(^|/)inventory/hosts\.yml$
(^|/)\.node-red/
\.p12$
\.pfx$
PATTERNS
[ "$BAD_TRACKED" -eq 0 ] && pass "no forbidden file patterns are tracked"

# Content scan across tracked files. Excludes this auditor, which necessarily
# contains the patterns it searches for.
CRED_HITS="$(git ls-files -z \
  | xargs -0 grep -lIE '(AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY|xox[baprs]-[0-9A-Za-z-]{10,})' 2>/dev/null \
  | grep -v 'scripts/audit.sh' || true)"
if [ -z "$CRED_HITS" ]; then
  pass "no credential patterns found in tracked content"
else
  fail "credential-shaped strings found in tracked files:"
  echo "$CRED_HITS" | sed 's/^/       /'
fi

# Live secret values must not appear in tracked content. Reads the real secret
# files from disk (they are gitignored) and greps the index for their contents.
LIVE_LEAK=0
for sf in $(find . -path ./.git -prune -o -type f -name '*password*.txt' -print 2>/dev/null; \
            find . -path ./.git -prune -o -type f -name 'postgres_password.txt' -print 2>/dev/null); do
  case "$sf" in *.example) continue;; esac
  [ -s "$sf" ] || continue
  VAL="$(tr -d '\r\n' < "$sf")"
  [ ${#VAL} -ge 8 ] || continue
  HIT="$(git ls-files -z | xargs -0 grep -lF "$VAL" 2>/dev/null || true)"
  if [ -n "$HIT" ]; then
    fail "the live secret in $sf appears in tracked content:"
    echo "$HIT" | sed 's/^/       /'
    LIVE_LEAK=1
  fi
done
[ "$LIVE_LEAK" -eq 0 ] && pass "no live secret value appears in tracked content"

# ------------------------------------------------------- 3. evidence logs ---
head2 "3. Evidence integrity"

EV_DIR="docs/evidence"
if [ ! -d "$EV_DIR" ]; then
  fail "$EV_DIR does not exist"
else
  LOG_COUNT="$(find "$EV_DIR" -name '*.log' -type f | wc -l)"
  info "$LOG_COUNT evidence log(s) found"

  BOM_BAD=0; ANSI_BAD=0; MOJI_BAD=0; TINY_BAD=0
  for f in "$EV_DIR"/*.log; do
    [ -e "$f" ] || continue
    NAME="$(basename "$f")"

    # UTF-8 BOM, so PowerShell 5.1 and Notepad decode the file correctly.
    if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' ')" != "efbbbf" ]; then
      fail "$NAME: missing UTF-8 BOM"
      BOM_BAD=1
    fi

    # Raw ANSI escapes are noise in a file meant to be read and quoted.
    if LC_ALL=C grep -q $'\x1b' "$f" 2>/dev/null; then
      fail "$NAME: contains ANSI escape sequences"
      ANSI_BAD=1
    fi

    # Mojibake: UTF-8 bytes that were decoded as Windows-1252 and re-encoded.
    if LC_ALL=C grep -qE 'â[€“”™]|Ã¢|â–|âœ|Ã©|Â ' "$f" 2>/dev/null; then
      fail "$NAME: contains mojibake (double-encoded UTF-8)"
      MOJI_BAD=1
    fi

    # A log too small to contain a command, output and an exit code is a stub.
    SZ="$(wc -c < "$f")"
    if [ "$SZ" -lt 200 ]; then
      fail "$NAME: only $SZ bytes - too small to be real evidence"
      TINY_BAD=1
    fi
  done

  [ "$BOM_BAD"  -eq 0 ] && pass "every evidence log carries a UTF-8 BOM"
  [ "$ANSI_BAD" -eq 0 ] && pass "no evidence log contains ANSI escapes"
  [ "$MOJI_BAD" -eq 0 ] && pass "no evidence log contains mojibake"
  [ "$TINY_BAD" -eq 0 ] && pass "every evidence log is a non-trivial size"

  UNTRACKED_EV="$(git ls-files --others --exclude-standard "$EV_DIR" | wc -l)"
  if [ "$UNTRACKED_EV" -eq 0 ]; then
    pass "every evidence log is tracked by git"
  else
    fail "$UNTRACKED_EV evidence file(s) exist on disk but are not tracked"
    git ls-files --others --exclude-standard "$EV_DIR" | sed 's/^/       /'
  fi
fi

# --------------------------------------------------- 4. report references ---
head2 "4. Report references resolve"

REPORT="docs/REPORT.md"
if [ ! -f "$REPORT" ]; then
  fail "$REPORT does not exist"
else
  # Every *.log filename mentioned anywhere in the report must exist on disk.
  # This is the check that catches a log deleted by an over-broad cleanup glob
  # while the report still cites it.
  REFS="$(grep -oE '[0-9A-Za-z._-]+\.log' "$REPORT" | sort -u)"
  REF_COUNT="$(echo "$REFS" | grep -c . || true)"
  info "$REF_COUNT distinct evidence file(s) referenced by the report"

  MISSING=0
  for ref in $REFS; do
    if [ ! -f "$EV_DIR/$ref" ]; then
      fail "REPORT.md references $ref which does not exist in $EV_DIR"
      MISSING=$((MISSING+1))
    fi
  done
  [ "$MISSING" -eq 0 ] && pass "all $REF_COUNT referenced evidence files exist"

  # The reverse direction is a warning, not a failure: an uncited log is
  # untidy, but it is not a false claim.
  for f in "$EV_DIR"/*.log; do
    [ -e "$f" ] || continue
    NAME="$(basename "$f")"
    grep -q "$NAME" "$REPORT" || info "note: $NAME exists but is not referenced by the report"
  done
fi

# ------------------------------------------------------ 4b. IaC hygiene ----
head2 "4b. Infrastructure-as-code hygiene"

# State is the dangerous one: it holds every generated password and private
# key in plaintext, so a committed .tfstate is a credential leak regardless of
# how harmless the resources look.
TFSTATE="$(git ls-files | grep -E "\.tfstate" || true)"
if [ -z "$TFSTATE" ]; then
  pass "no terraform state file is tracked"
else
  fail "terraform state is TRACKED - it contains secrets in plaintext:"
  echo "$TFSTATE" | sed "s/^/       /"
fi

# tfvars may carry a real project id, key material or an admin CIDR. The
# .example is the tracked one.
TFVARS="$(git ls-files | grep -E "terraform\.tfvars$" || true)"
if [ -z "$TFVARS" ]; then
  pass "no terraform.tfvars with real values is tracked (only .example)"
else
  fail "terraform.tfvars is TRACKED:"
  echo "$TFVARS" | sed "s/^/       /"
fi

# An ed25519 private key has no extension at all, so *.pem / *.key / id_rsa
# all miss it. This is how a generated task05_ed25519 came within one
# `git add -A` of being committed.
SSHKEYS="$(git ls-files | grep -E "\.ssh/" | grep -vE "\.pub$" || true)"
if [ -z "$SSHKEYS" ]; then
  pass "no SSH private key is tracked"
else
  fail "an SSH private key is TRACKED:"
  echo "$SSHKEYS" | sed "s/^/       /"
fi

# A generated inventory pins live public addresses into git and goes stale the
# moment the estate is rebuilt.
INV="$(git ls-files | grep -E "inventory/hosts\.yml$" || true)"
if [ -z "$INV" ]; then
  pass "no generated Ansible inventory is tracked"
else
  fail "a generated inventory is TRACKED (it pins live addresses):"
  echo "$INV" | sed "s/^/       /"
fi

# Terraform must be formatted, so a diff is a real change and not whitespace.
if command -v terraform > /dev/null 2>&1 && [ -d 05-terraform-ansible/terraform ]; then
  if (cd 05-terraform-ansible/terraform && MSYS_NO_PATHCONV=1 terraform fmt -check -recursive > /dev/null 2>&1); then
    pass "terraform fmt -check is clean"
  else
    fail "terraform files are not formatted; run terraform fmt"
  fi
else
  info "terraform not installed or no config present; fmt check skipped"
fi

# Anything still running is still billing.
if command -v gcloud > /dev/null 2>&1; then
  LIVE="$(env -u MSYS_NO_PATHCONV gcloud compute instances list --format="value(name)" 2>/dev/null | grep -c task05 || true)"
  if [ "${LIVE:-0}" -eq 0 ]; then
    pass "no task05 GCP instances are running (nothing billing)"
  else
    fail "${LIVE} task05 instance(s) still RUNNING and billing"
  fi
else
  info "gcloud not available; live-resource check skipped"
fi

# ------------------------------------------------- 4c. cloud credentials ---
head2 "4c. Cloud credential hygiene (this repository is PUBLIC)"

# An AWS account id is not a secret the way a key is, but publishing it aids
# targeted phishing, bucket enumeration and cross-account role guessing.
ARN_HITS="$(git ls-files -z | xargs -0 grep -lE "arn:aws[a-z-]*:[a-z0-9-]+:[a-z0-9-]*:[0-9]{12}:" 2>/dev/null | grep -v scripts/audit.sh | grep -v scripts/redact.sh || true)"
if [ -z "$ARN_HITS" ]; then
  pass "no ARN containing a literal account id is tracked"
else
  fail "ARN with an account id found in tracked files:"
  echo "$ARN_HITS" | sed "s/^/       /"
fi

# Identity is not only AWS. A preflight log once published a GCP billing account
# id and a work email, because the redactor covered one cloud and the work used
# two. Two classes are deliberately allowed: service-account addresses, which
# name infrastructure, and the repository's own commit-author address, which is
# already public in every commit and whose removal would break attribution.
AUTHOR_EMAIL="$(git log -1 --format='%ae' 2>/dev/null || echo '')"
IDENT_HITS=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  case "$f" in scripts/audit.sh|scripts/redact.sh|.claude/agents/*|*/redact.sh) continue ;; esac
  FOUND="$(grep -ohE 'billingAccounts/[0-9A-Za-z]{6}-[0-9A-Za-z]{6}-[0-9A-Za-z]{6}|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}' "$f" 2>/dev/null             | grep -v 'gserviceaccount\.com'             | grep -v 'example\.com\|@task05\|noreply@'             | { [ -n "$AUTHOR_EMAIL" ] && grep -vF "$AUTHOR_EMAIL" || cat; }             | sort -u || true)"
  if [ -n "$FOUND" ]; then
    IDENT_HITS="${IDENT_HITS}${f}: $(echo "$FOUND" | tr '
' ' ')
"
  fi
done <<< "$(git ls-files)"
IDENT_HITS="$(echo "$IDENT_HITS" | grep -v '^$' || true)"
if [ -z "$IDENT_HITS" ]; then
  pass "no billing-account id or third-party personal email is tracked"
else
  fail "a cloud billing id or personal email is TRACKED:"
  echo "$IDENT_HITS" | sed "s/^/       /"
fi

# AWS config and credential files must never be tracked.
AWSCFG="$(git ls-files | grep -E "(^|/)[.]aws/|(^|/)credentials$" || true)"
if [ -z "$AWSCFG" ]; then
  pass "no AWS config or credentials file is tracked"
else
  fail "an AWS credentials file is TRACKED:"
  echo "$AWSCFG" | sed "s/^/       /"
fi

# Media artefacts are large and regenerable; they do not belong in git.
MEDIA="$(git ls-files | grep -E "[.](ts|mxf|mkv|mp4|flv)$" || true)"
if [ -z "$MEDIA" ]; then
  pass "no large media artefacts are tracked (regenerable from scripts)"
else
  fail "media files are tracked:"
  echo "$MEDIA" | sed "s/^/       /"
fi

# A running MediaLive channel bills per hour even with no input at all.
AWSBIN="$(command -v aws 2>/dev/null || echo /c/Program\ Files/Amazon/AWSCLIV2/aws)"
if [ -x "$AWSBIN" ] || command -v aws > /dev/null 2>&1; then
  RUNNING="$(env -u MSYS_NO_PATHCONV AWS_PAGER='' aws medialive list-channels --region "${AWS_REGION:-eu-central-1}" --query 'length(Channels[?State==`RUNNING`])' --output text 2>/dev/null || echo 0)"
  case "${RUNNING:-0}" in
    0|None|"") pass "no MediaLive channel is RUNNING (nothing billing)" ;;
    *) fail "${RUNNING} MediaLive channel(s) RUNNING and billing now" ;;
  esac
else
  info "aws CLI unavailable; MediaLive running-channel check skipped"
fi

# ------------------------------------------------------ 5. report honesty ---
head2 "5. Shipped documents"

if [ -f "$REPORT" ]; then
  TBD_LINES="$(grep -nE '_TBD|<placeholder>|TODO|FIXME' "$REPORT" || true)"
  if [ -z "$TBD_LINES" ]; then
    pass "no placeholder markers remain in the report"
  else
    fail "the report still holds placeholder markers:"
    echo "$TBD_LINES" | sed "s/^/       /"
  fi
fi

# Internal review vocabulary does not ship. Evidence logs are excluded: they are
# captured output and are never edited, only re-run.
BANNED='PARTIALLY EXECUTED|VALIDATED-NOT-APPLIED|SUPERSEDED|Status: EXECUTED|false green|findings ledger'
VOCAB_HITS=""
while IFS= read -r f; do
  case "$f" in
    docs/evidence/*) continue ;;
    scripts/audit.sh) continue ;;
  esac
  case "$f" in
    *.md|*.MD)
      H="$(grep -nE "$BANNED" "$f" 2>/dev/null | head -3 || true)"
      [ -n "$H" ] && VOCAB_HITS="$VOCAB_HITS$f: $(echo "$H" | head -1)
"
      ;;
  esac
done <<< "$(git ls-files)"
VOCAB_HITS="$(echo "$VOCAB_HITS" | grep -v '^$' || true)"
if [ -z "$VOCAB_HITS" ]; then
  pass "shipped documents carry no internal review vocabulary"
else
  fail "internal review vocabulary found in shipped documents:"
  echo "$VOCAB_HITS" | sed "s/^/       /"
fi

# CLAUDE.md is the lead working brief and sits beside the reviewer briefs. It
# should carry no residue of the handoff it grew out of.
STALE='as established with the user|Phase A|Phase B|PHASE-B-CHECKLIST|the user'
if [ -f CLAUDE.md ]; then
  SH="$(grep -nEi "$STALE" CLAUDE.md || true)"
  if [ -z "$SH" ]; then
    pass "CLAUDE.md reads as a working brief, with no handoff residue"
  else
    fail "CLAUDE.md still carries handoff residue:"
    echo "$SH" | sed "s/^/       /"
  fi
fi

# The reviewer briefs are addressed by name; the working titles they replaced
# should not survive anywhere in the tree.
OLDNAMES='test-forensics|claim-auditor|security-sentinel|cost-sentinel|reproducibility-verifier|report-writer|examiner'
NAME_HITS=""
while IFS= read -r f; do
  case "$f" in scripts/audit.sh) continue ;; esac
  H="$(grep -nE "$OLDNAMES" "$f" 2>/dev/null | head -2 || true)"
  [ -n "$H" ] && NAME_HITS="$NAME_HITS$f: $(echo "$H" | head -1)
"
done <<< "$(git ls-files)"
NAME_HITS="$(echo "$NAME_HITS" | grep -v '^$' || true)"
if [ -z "$NAME_HITS" ]; then
  pass "no superseded reviewer identifiers remain in tracked files"
else
  fail "superseded reviewer identifiers found:"
  echo "$NAME_HITS" | sed "s/^/       /"
fi

# The seven briefs exist and each declares the name it is filed under.
BRIEF_OK=1
for n in faris adel amin hasib ghareeb rawi fahim; do
  if [ ! -f ".claude/agents/$n.md" ]; then
    fail "missing reviewer brief: .claude/agents/$n.md"; BRIEF_OK=0; continue
  fi
  if ! grep -q "^name: $n$" ".claude/agents/$n.md"; then
    fail "brief .claude/agents/$n.md does not declare name: $n"; BRIEF_OK=0
  fi
done
[ "$BRIEF_OK" -eq 1 ] && pass "all seven reviewer briefs present, each declaring its own name"

head2 "6. Submission artefacts"

# The shipped evidence set is the six task series plus the document check.
# Anything numbered above that is internal material that should not ship.
STRAY="$(ls "$EV_DIR" 2>/dev/null | grep -E '^(0[89]|[1-9][0-9])-' || true)"
if [ -z "$STRAY" ]; then
  pass "evidence set stops at 07, with no internal material shipped"
else
  fail "evidence files numbered above 07 are present:"
  echo "$STRAY" | sed "s/^/       /"
fi

# The history opens with the nine-commit build arc, in order. Completion work
# lands on top of it rather than being folded back in, so the tip moves; what
# should not move is the arc beneath it.
ARC="chore: project scaffold and delivery method
feat(01): cross-platform SMB mounts, XFS, monitoring and alerting
feat(02): multi-tier Docker stack on isolated networks
feat(03): SQL Server with tiered backups and point-in-time restore
feat(04): S3 multipart copy engine and Node-RED flow
feat(05): three-tier GCP infrastructure with Terraform and Ansible
feat(06): HEVC pipeline and MediaLive channel with S3 archive
docs: report, traceability, walkthroughs and reproducing guide
chore: PDF and DOCX deliverables"
ACTUAL="$(git log --reverse --format='%s' 2>/dev/null | head -9)"
if [ "$ACTUAL" = "$ARC" ]; then
  pass "history opens with the nine-commit build arc, in order"
else
  fail "the first nine commits are not the build arc:"
  diff <(echo "$ARC") <(echo "$ACTUAL") 2>/dev/null | sed "s/^/       /" | head -12
fi

# Traceability must cover every sub-requirement, and its status vocabulary is
# fixed at three values. A fourth would mean the table had drifted.
TRACE="docs/TRACEABILITY.md"
if [ -f "$TRACE" ]; then
  TROWS="$(grep -cE '^\| [0-9]+\.[0-9]+ \|' "$TRACE" || true)"
  if [ "${TROWS:-0}" -ge 32 ]; then
    pass "TRACEABILITY.md maps $TROWS sub-requirements"
  else
    fail "TRACEABILITY.md maps only ${TROWS:-0} sub-requirements, expected 32"
  fi
  if grep -qiE '\| *(EXECUTED|PARTIALLY EXECUTED|EXCEEDED) *\|' "$TRACE"; then
    fail "TRACEABILITY.md still carries a status column"
  else
    pass "TRACEABILITY.md maps requirement to delivery without status vocabulary"
  fi
else
  fail "docs/TRACEABILITY.md is missing"
fi

# The PDF verification must exist and must record a pass. A missing or failing
# log here means the deliverable was never checked, or was checked and failed.
PDFLOG="$EV_DIR/07-pdf-verification.log"
if [ -f "$PDFLOG" ]; then
  if grep -q "RESULT: PDF VERIFIED" "$PDFLOG"; then
    PDFPAGES="$(grep -oE '^pages[[:space:]]*:[[:space:]]*[0-9]+' "$PDFLOG" | grep -oE '[0-9]+' | head -1)"
    # PDFPAGES is the physical count the verifier prints, cover included. The
    # folios printed on the pages run to one fewer, and stating which is which
    # is the point of naming it here rather than leaving two numbers loose.
    if [ "${PDFPAGES:-999}" -le 20 ]; then
      pass "PDF verification recorded a pass (${PDFPAGES:-?} physical pages, $(( ${PDFPAGES:-1} - 1 )) numbered + cover, within the 20-page limit)"
    else
      fail "PDF is ${PDFPAGES} physical pages, over the 20-page limit"
    fi
  else
    fail "07-pdf-verification.log exists but does not record RESULT: PDF VERIFIED"
  fi
else
  fail "docs/evidence/07-pdf-verification.log is missing"
fi

for f in REPORT.pdf REPORT.docx; do
  if [ -s "$f" ]; then
    pass "$f is present ($(du -k "$f" | cut -f1) KB)"
  else
    fail "$f is missing or empty"
  fi
done

# ------------------------------------------------------------------ summary -
echo ""
echo "================================================================"
if [ "$FAILURES" -eq 0 ]; then
  echo "AUDIT PASSED - $CHECKS checks, 0 failures"
else
  echo "AUDIT FAILED - $CHECKS checks, $FAILURES failure(s)"
fi
echo "================================================================"
exit "$FAILURES"
