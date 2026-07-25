#!/bin/bash
# Harness for wait_for_healthcheck in .buildkite/scripts/deploy_production.sh
#
# That script is never executed by CI (it only ever gets `bash -n`), so this harness is the
# only test the deploy gate has. It drives the SHIPPED function, extracted from the real file
# with awk rather than retyped, so the test cannot drift from the code that deploys.
#
# The `date` stub resolves real timezones from a fixed epoch via python zoneinfo, so a case can
# pin behaviour at any wall-clock hour without waiting for it.
#
# Usage: ./deploy_production_test.sh            run the cases
#        ./deploy_production_test.sh --mutate   also prove each case FAILS against broken
#                                               variants of the real script (anti-vacuity check)
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/deploy_production.sh"
STUB_DIR=$(mktemp -d)
trap 'rm -rf "$STUB_DIR"' EXIT

# --- stub `date`: honours -u and $TZ against $FAKE_EPOCH, real tzdata rules ---
cat > "$STUB_DIR/date" <<'STUB'
#!/usr/bin/env bash
python3 - "$@" <<'PY'
import os, sys, datetime
from zoneinfo import ZoneInfo
args = sys.argv[1:]
tz = ZoneInfo("UTC") if "-u" in args else ZoneInfo(os.environ.get("TZ") or "UTC")
t = datetime.datetime.fromtimestamp(int(os.environ["FAKE_EPOCH"]), tz)
fmt = next((a for a in args if a.startswith("+")), "+%c")[1:]
out = fmt.replace("%-H", str(t.hour)).replace("%H", f"{t.hour:02d}")
out = out.replace("%u", str(t.isoweekday()))
print(out)
PY
STUB
# `sleep` must not really sleep (the 503 path waits 3 minutes per attempt)
printf '#!/bin/bash\nexit 0\n' > "$STUB_DIR/sleep"
chmod +x "$STUB_DIR/date" "$STUB_DIR/sleep"

# --- extract the shipped function + its logger, no retyping ---
extract() {
  { awk '/^logger\(\) \{/,/^\}/' "$SCRIPT"
    awk '/^wait_for_healthcheck\(\) \{/,/^\}/' "$SCRIPT"
  } > "$STUB_DIR/fn.sh"
  [ -s "$STUB_DIR/fn.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
}

# The real call sites, so the harness tests the ARGUMENTS that actually ship too.
LONG_ARGS=$(awk '/^wait_for_healthcheck "Long-running job"/,/^$/' "$SCRIPT" | tr -d '\\\n')
PAYOUT_ARGS=$(awk '/^wait_for_healthcheck "Payout batch"/,/^$/' "$SCRIPT" | tr -d '\\\n')

# epoch for a given UTC hour on a date (2026-01-15 = EST, 2026-07-15 = EDT)
epoch_for() { python3 -c "
import datetime,sys
from zoneinfo import ZoneInfo
d,h=sys.argv[1],int(sys.argv[2])
print(int(datetime.datetime.strptime(d,'%Y-%m-%d').replace(hour=h,minute=30,tzinfo=ZoneInfo('UTC')).timestamp()))" "$1" "$2"; }

# Run one scenario -> prints DEPLOY or SKIP
# args: <status-sequence> <date> <utc-hour> <call: long|payouts>
run_case() {
  local statuses="$1" day="$2" hour="$3" which="$4"
  local call; [ "$which" = "long" ] && call="$LONG_ARGS" || call="$PAYOUT_ARGS"
  # curl is invoked inside $( ), i.e. a subshell, so the status queue has to live in a FILE
  # rather than a shell variable or each call would pop from an unmodified copy.
  local queue="$STUB_DIR/queue"; printf '%s\n' $statuses > "$queue"
  FAKE_EPOCH=$(epoch_for "$day" "$hour") \
  QUEUE="$queue" PATH="$STUB_DIR:$PATH" \
  bash -c "
    set -e
    curl() {
      local s; s=\$(head -1 \"\$QUEUE\")
      # last entry repeats forever, mimicking a persistently unhealthy endpoint
      [ \$(wc -l < \"\$QUEUE\") -gt 1 ] && tail -n +2 \"\$QUEUE\" > \"\$QUEUE.t\" && mv \"\$QUEUE.t\" \"\$QUEUE\"
      echo \"\$s\"
    }
    source '$STUB_DIR/fn.sh'
    $call
    echo REACHED_DEPLOY_BODY
  " > "$STUB_DIR/out" 2>/dev/null
  # the log lines stay in $STUB_DIR/out so check_log can assert on them afterwards
  grep -q REACHED_DEPLOY_BODY "$STUB_DIR/out" && echo DEPLOY || echo SKIP
}

PASS=0; FAIL=0
check() { # <desc> <expected> <statuses> <day> <hour> <call>
  local desc="$1" exp="$2"; shift 2
  local got; got=$(run_case "$@")
  if [ "$got" = "$exp" ]; then PASS=$((PASS+1)); [ -n "${QUIET:-}" ] || echo "PASS: $desc -> $got"
  else FAIL=$((FAIL+1)); echo "FAIL: $desc -> got $got, expected $exp"; fi
}

# Same as check(), but asserts on what the run LOGGED rather than on deploy/skip. Some branches
# exist only for the diagnostic value of their log line, and a case on the outcome alone cannot
# tell whether the branch is still there.
check_log() { # <desc> <expected-substring> <statuses> <day> <hour> <call>
  local desc="$1" pat="$2"; shift 2
  run_case "$@" >/dev/null
  if grep -qF -- "$pat" "$STUB_DIR/out"; then PASS=$((PASS+1)); [ -n "${QUIET:-}" ] || echo "PASS: $desc"
  else FAIL=$((FAIL+1)); echo "FAIL: $desc -> log did not contain: $pat"; fi
}

cases() {
  D=2026-07-15
  # --- steady state: endpoint deployed and answering ---
  check "200 nothing in flight deploys"                    DEPLOY "200" $D 2  long
  check "200 deploys even inside every window"             DEPLOY "200" $D 5  long
  # --- 503 in-flight loop then clear (the sleep path) ---
  check "503 then 200 waits then deploys"                  DEPLOY "503 503 200" $D 2 long
  # --- 404: no interpretable answer, so the WIDE fail-safe window decides, same as a 5xx.
  #     The long-running-job window is UTC 00-05 and 08-13. ---
  check "404 at 02 UTC inside fail-safe window skips"      SKIP   "404" $D 2  long
  check "404 at 12 UTC inside report hours skips"          SKIP   "404" $D 12 long
  check "404 at 06 UTC outside the window proceeds"        DEPLOY "404" $D 6  long
  check "404 at 20 UTC outside the window proceeds"        DEPLOY "404" $D 20 long
  # --- the 404 branch exists for its distinct log line: a live endpoint that starts 404ing
  #     means a renamed/removed route, a web-only rollback, or an edge 404, and the deploy log
  #     should say so rather than call it unreachable. Assert the wording, both directions. ---
  check_log "404 skip logs it as absent, not unreachable"  "absent (HTTP 404) inside the fail-safe window" "404" $D 2  long
  check_log "404 proceed logs it as absent too"            "absent (HTTP 404) outside the fail-safe window" "404" $D 20 long
  check_log "5xx still logs as unreachable"                "unreachable (HTTP 500)" "500" $D 2 long
  # --- genuinely broken endpoint uses the same window ---
  check "500 at 02 UTC skips (conservative)"               SKIP   "500" $D 2  long
  check "500 at 12 UTC skips (report window)"              SKIP   "500" $D 12 long
  check "000 unreachable at 20 UTC proceeds"               DEPLOY "000" $D 20 long
  check "500 at 20 UTC outside all windows proceeds"       DEPLOY "500" $D 20 long
  # --- the payouts call has its own, much narrower window: Tue-Fri UTC 10. ---
  check "payouts 404 inside its window skips"              SKIP   "404" 2026-07-14 10 payouts
  check "payouts 404 outside its window proceeds"          DEPLOY "404" $D 20 payouts
  check "payouts 500 inside its window skips"              SKIP   "500" 2026-07-14 10 payouts
}

extract
echo "=== wait_for_healthcheck cases ==="
cases
echo
echo "PASS=$PASS FAIL=$FAIL"
BASE_FAIL=$FAIL

# ---------------------------------------------------------------------------
# Mutation testing: each mutation below MUST make the suite fail. This is what
# proves the cases are load-bearing rather than vacuously passing.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--mutate" ]; then
  echo
  echo "=== mutation testing (each mutant MUST be caught) ==="
  mutate() { # <desc> <sed-expr>
    local desc="$1" expr="$2"
    cp "$SCRIPT" "$STUB_DIR/orig.sh"
    perl -0pi -e "$expr" "$SCRIPT"
    if diff -q "$STUB_DIR/orig.sh" "$SCRIPT" >/dev/null; then
      echo "SKIP (mutation did not apply): $desc"; cp "$STUB_DIR/orig.sh" "$SCRIPT"; return
    fi
    extract
    LONG_ARGS=$(awk '/^wait_for_healthcheck "Long-running job"/,/^$/' "$SCRIPT" | tr -d '\\\n')
    PAYOUT_ARGS=$(awk '/^wait_for_healthcheck "Payout batch"/,/^$/' "$SCRIPT" | tr -d '\\\n')
    PASS=0; FAIL=0; QUIET=1 cases
    if [ "$FAIL" -gt 0 ]; then echo "CAUGHT ($FAIL failing): $desc"
    else echo "ESCAPED -- suite is vacuous for: $desc"; ESCAPES=$((ESCAPES+1)); fi
    cp "$STUB_DIR/orig.sh" "$SCRIPT"
    extract
    LONG_ARGS=$(awk '/^wait_for_healthcheck "Long-running job"/,/^$/' "$SCRIPT" | tr -d '\\\n')
    PAYOUT_ARGS=$(awk '/^wait_for_healthcheck "Payout batch"/,/^$/' "$SCRIPT" | tr -d '\\\n')
  }
  ESCAPES=0
  mutate "delete the whole 404 branch (loses its diagnostic log line)" \
    's/    elif \[ "\$hc_status" = "404" \]; then.*?      return 0\n(    else)/$1/s'
  mutate "404 branch ignores the window and always skips" \
    's/(= "404" \]; then\n      )if eval "\$failsafe_window_test"; then/${1}if true; then/'
  mutate "404 skip uses return instead of exit (deploy proceeds anyway)" \
    's/(absent \(HTTP 404\) inside the fail-safe window — skipping deployment"\n        )exit 0/${1}return 0/'
  mutate "off-by-one: fail-safe window overnight leg becomes -le 6" \
    "s/(date -u \\+%-H\\)\" -le )5/\${1}6/"
  mutate "fail-safe window loses its report-hours leg (08-13 becomes 18-13)" \
    's/-ge 8 \]/-ge 18 ]/'
  echo
  echo "MUTANTS_ESCAPED=$ESCAPES"
  [ "$ESCAPES" -eq 0 ] && [ "$BASE_FAIL" -eq 0 ] && echo "ALL GREEN: cases pass, every mutant caught"
fi

[ "$BASE_FAIL" -eq 0 ] || exit 1
