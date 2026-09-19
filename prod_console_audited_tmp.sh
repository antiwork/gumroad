#!/usr/bin/env bash
# Audit-gated wrapper for the read-only Gumroad prod console.
# Writes the MANDATORY S3 audit log BEFORE connecting and a result object AFTER,
# using the two-profile dance (default profile for S3 writes, gumroad-prod for the hop).
# Confirmed working end-to-end June 2026.
#
# Usage:
#   ./prod_console_audited.sh "<intent>" "<linked_ref>" '<ruby_command>'
# Example:
#   ./prod_console_audited.sh \
#     "Verify subscription status for refund ticket" \
#     "helper:4f53220e..." \
#     'puts Subscription.find(2746843).cancelled_at.to_s'
#
# Notes:
# - Run from the antiwork/gumroad repo root (needs .agents/skills/gumroad-prod-console/scripts/prod_query.sh).
# - Read-only ONLY. Never pass a write/update/delete command.
# - If the S3 audit write fails, the script STOPS and does NOT connect.
#
# REPLICA FRESHNESS GUARD (added 2026-07-27 after gumroad-private#1353)
# --------------------------------------------------------------------
# Every read here goes to DATABASE_WORKER_REPLICA1_HOST (the default in
# prod_query.sh). In July 2026 that replica fell up to 5h12m behind the primary
# because one applier thread was wedged on a hot-row UPDATE. Replication never
# errored, so the queries still SUCCEEDED — they just described a world hours in
# the past. Any window-scoped count ("how many purchases in the last 10 minutes")
# quietly returned 0, and a monitor reading through here reported healthy while
# seeing no data at all. That is the dangerous shape: silent staleness, not failure.
#
# So before trusting any result, this script measures how old the replica's newest
# purchase row is and refuses to hand back data from a replica that is further
# behind than PROD_MAX_LAG seconds. A caller that gets no data can react; a caller
# handed stale zeros cannot tell it is blind.
#
# Knobs:
#   PROD_MAX_LAG=900          max acceptable staleness in seconds (default 900 = 15 min)
#   PROD_SKIP_FRESHNESS=1     skip the check entirely — only for queries where age
#                             genuinely does not matter (historical/backfill reads)
#   PROD_FAILOVER_HOSTS="A B" env var NAMES to retry with when the default is stale.
#                             Empty by default ON PURPOSE: since production-metabase-replica
#                             was deleted, worker-replica-1 is the only live read replica —
#                             the remaining candidates resolve to the primary WRITER, and
#                             silently moving an arbitrary (possibly heavy) query onto the
#                             writer is worse than failing. Opt in per-caller for cheap reads.
# Exit 75 (EX_TEMPFAIL) means "replica too stale to answer" — distinct from a real error.

set -uo pipefail

INTENT="${1:?intent (plain-language reason) required}"
LINKED_REF="${2:-none}"
CMD="${3:?ruby command required}"

MAX_LAG="${PROD_MAX_LAG:-900}"
SKIP_FRESHNESS="${PROD_SKIP_FRESHNESS:-0}"
FAILOVER_HOSTS="${PROD_FAILOVER_HOSTS:-}"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
QUERY_SH="$REPO_ROOT/.agents/skills/gumroad-prod-console/scripts/prod_query.sh"
if [[ ! -x "$QUERY_SH" ]]; then
  echo "ERROR: prod_query.sh not found/executable at $QUERY_SH — run from the gumroad repo root." >&2
  exit 1
fi

REQ_ID="$(python3 -c 'import time,uuid;print(time.strftime("%Y%m%dT%H%M%SZ",time.gmtime())+"-"+uuid.uuid4().hex[:8])')"
SHA="$(printf '%s' "$CMD" | shasum -a 256 | cut -d' ' -f1)"
DAY="$(date -u +'%Y/%m/%d')"
BASE="gumclaw/production-console-access/$DAY/$REQ_ID"
NOW="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# 1. Build the running record
python3 - "$REQ_ID" "$INTENT" "$LINKED_REF" "$CMD" "$SHA" "$NOW" > "/tmp/console-audit-$REQ_ID.json" <<'PY'
import json,sys
rid,intent,ref,cmd,sha,now=sys.argv[1:7]
json.dump({
 "request_id":rid,"requested_by":"unknown-set-by-caller","requested_by_channel":"telegram",
 "actor":"gumclaw","actor_ssh_key_fingerprint":"prod_query.sh-bastion",
 "intent":intent,"linked_ref":ref,"command":cmd,"command_sha256":sha,
 "read_only":True,"operation_class":"query","target_type":"mixed","db_role":"readonly_replica",
 "status":"running","created_at":now
}, sys.stdout, indent=2)
PY

# 2. LOG FIRST — default profile (gumclaw user has s3:PutObject; ListBucket is denied, that's fine)
( unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  aws s3 cp "/tmp/console-audit-$REQ_ID.json" "s3://gumroad-logs/$BASE.json" --region us-east-1 ) || {
  echo "ERROR: audit-log write failed — NOT connecting to console." >&2; exit 1; }

# 3. Connect & run — gumroad-prod profile for EC2 discovery + bastion hop
#
# The command we actually send is the caller's Ruby with a small freshness probe
# prepended. The probe prints one sentinel line reporting how many seconds old the
# newest purchase row is; we read that line, strip it out, and only then decide
# whether the rest of the output can be trusted. Doing the probe in the SAME hop as
# the query matters — a separate probe connection could land on a different host or
# a different moment and tell you about a replica you did not read from.
if [[ "$SKIP_FRESHNESS" == "1" ]]; then
  PROBE=""
else
  PROBE='require "time"
begin
  __row = ActiveRecord::Base.connection.select_value("SELECT created_at FROM purchases ORDER BY id DESC LIMIT 1")
  __t = __row.is_a?(String) ? Time.parse(__row.to_s + " UTC") : (__row && __row.to_time.utc)
  puts "GUMREPLICA_LAG=" + (__t ? (Time.now.utc - __t).round.to_s : "999999")
rescue StandardError
  puts "GUMREPLICA_LAG=-1"
end
'
fi

run_hop() {  # $1 = env var name to pin as DATABASE_HOST, or empty for the default
  local hostvar="$1"
  if [[ -n "$hostvar" ]]; then
    echo "$PROBE$CMD" | AWS_PROFILE=gumroad-prod PROD_DB_HOST_VAR="$hostvar" timeout 120 "$QUERY_SH" 2>&1
  else
    echo "$PROBE$CMD" | AWS_PROFILE=gumroad-prod timeout 120 "$QUERY_SH" 2>&1
  fi
}

START=$(date +%s)
OUT="$(run_hop "")"; RC=$?
LAG="$(printf '%s\n' "$OUT" | grep -m1 '^GUMREPLICA_LAG=' | cut -d= -f2 | tr -d '[:space:]')"
case "$LAG" in ''|*[!0-9-]*) LAG="unknown" ;; esac
USED_HOST="${PROD_DB_HOST_VAR:-DATABASE_WORKER_REPLICA1_HOST}"

# Stale? Try the caller's opt-in failover hosts before giving up.
if [[ "$SKIP_FRESHNESS" != "1" && "$LAG" != "unknown" && "$LAG" -gt "$MAX_LAG" ]]; then
  for hv in $FAILOVER_HOSTS; do
    >&2 echo "WARN: replica ${LAG}s stale (max ${MAX_LAG}s) — retrying via \$$hv"
    OUT="$(run_hop "$hv")"; RC=$?
    LAG="$(printf '%s\n' "$OUT" | grep -m1 '^GUMREPLICA_LAG=' | cut -d= -f2 | tr -d '[:space:]')"
    case "$LAG" in ''|*[!0-9-]*) LAG="unknown" ;; esac
    USED_HOST="$hv"
    [[ "$LAG" != "unknown" && "$LAG" -le "$MAX_LAG" ]] && break
  done
fi

# Drop the sentinel so callers parse exactly what they parsed before this guard existed.
OUT="$(printf '%s\n' "$OUT" | grep -v '^GUMREPLICA_LAG=')"

DUR=$(( ($(date +%s) - START) * 1000 ))
RESULT_SHA="$(printf '%s' "$OUT" | shasum -a 256 | cut -d' ' -f1)"
ROWS="$(printf '%s' "$OUT" | grep -c '.' || true)"
[[ $RC -eq 0 ]] && STATUS=ok || { [[ $RC -eq 124 ]] && STATUS=timeout || STATUS=error; }

# The whole point of the guard: a read from a too-stale replica is NOT a result.
# Mark it, log it, and withhold the output so nothing downstream can mistake
# hours-old zeros for a quiet production.
STALE=0
if [[ "$SKIP_FRESHNESS" != "1" && $RC -eq 0 ]]; then
  if [[ "$LAG" == "unknown" || "$LAG" == "-1" ]]; then
    STALE=1; STATUS=freshness_unknown
  elif [[ "$LAG" -gt "$MAX_LAG" ]]; then
    STALE=1; STATUS=stale_replica
  fi
fi
DONE="$(date -u +'%Y-%m-%dT%H:%M:%SZ')"

# 4. LOG THE RESULT — never store raw PII output, only a digest + summary
python3 - "$REQ_ID" "$STATUS" "$ROWS" "$RESULT_SHA" "$DUR" "$DONE" "$LAG" "$USED_HOST" > "/tmp/console-audit-$REQ_ID-result.json" <<'PY'
import json,sys
rid,status,rows,digest,dur,done,lag,host=sys.argv[1:9]
json.dump({"request_id":rid,"status":status,
 "result_summary":"see digest; raw output not stored",
 "result_row_count":int(rows or 0),"result_digest":digest,
 "duration_ms":int(dur),"completed_at":done,
 "replica_lag_s":lag,"db_host_var":host}, sys.stdout, indent=2)
PY
( unset AWS_PROFILE AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  aws s3 cp "/tmp/console-audit-$REQ_ID-result.json" "s3://gumroad-logs/$BASE-result.json" --region us-east-1 >/dev/null ) \
  || echo "WARN: result audit-log write failed (command already ran)." >&2

LAG_DISPLAY="$LAG"; [[ "$LAG" =~ ^[0-9]+$ ]] && LAG_DISPLAY="${LAG}s"
echo "=== request_id: $REQ_ID  status: $STATUS  ${DUR}ms  replica_lag=${LAG_DISPLAY}  host=${USED_HOST} ===" >&2

if [[ $STALE -eq 1 ]]; then
  echo "ERROR: replica freshness check failed (lag=${LAG_DISPLAY}, max=${MAX_LAG}s, host=${USED_HOST})." >&2
  echo "       Output withheld — stale reads look like healthy-but-quiet data and cannot be told apart." >&2
  echo "       Set PROD_FAILOVER_HOSTS to retry elsewhere, PROD_MAX_LAG to widen, or PROD_SKIP_FRESHNESS=1" >&2
  echo "       if the query genuinely does not care about recency. See gumroad-private#1353." >&2
  exit 75
fi

printf '%s\n' "$OUT"
exit $RC
