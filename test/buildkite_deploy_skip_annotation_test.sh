#!/bin/bash
# Exercises the skip path of deploy_production.sh without running a deploy (gp#2635).
#
# A skipped deploy must leave a Buildkite annotation naming the reason and the commit, and
# must still exit 0 — the skip is deliberate, so the build stays green; only the signal was
# missing. Extracts the two functions under test from the real script (no copy to drift) and
# drives them with a stubbed curl / buildkite-agent.
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.buildkite/scripts/deploy_production.sh"
[ -f "$SCRIPT" ] || { echo "FAIL: $SCRIPT not found"; exit 1; }

HARNESS=$(mktemp)
python3 - "$SCRIPT" "$HARNESS" <<'PY'
import pathlib, sys
src = pathlib.Path(sys.argv[1]).read_text().splitlines()
start = next(i for i, l in enumerate(src) if l.startswith("logger() {"))
w = next(i for i, l in enumerate(src) if l.startswith("wait_for_healthcheck() {"))
depth, end = 0, None
for i in range(w, len(src)):
    depth += src[i].count("{") - src[i].count("}")
    if depth == 0 and i > w:
        end = i
        break
assert end, "could not find the end of wait_for_healthcheck"
pathlib.Path(sys.argv[2]).write_text("\n".join(src[start:end + 1]) + "\n")
PY

BIN=$(mktemp -d)
export ANN_FILE=$(mktemp) STUB_STATUS=200
cat > "$BIN/buildkite-agent" <<'STUB'
#!/bin/bash
echo "$*" >> "$ANN_FILE"
STUB
cat > "$BIN/curl" <<'STUB'
#!/bin/bash
echo -n "$STUB_STATUS"
STUB
# 503 waits 3 minutes between attempts; a no-op sleep keeps the timeout case testable.
cat > "$BIN/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$BIN/buildkite-agent" "$BIN/curl" "$BIN/sleep"
export PATH="$BIN:$PATH"

PASS=0; FAIL=0
check() { # <name> <expected-exit> <expected-substring-or-'' in annotation>
  local name="$1" want_exit="$2" want_text="$3" got_exit="$4"
  local ann; ann=$(cat "$ANN_FILE")
  if [ "$got_exit" != "$want_exit" ]; then
    echo "FAIL $name: exit $got_exit, wanted $want_exit"; FAIL=$((FAIL + 1)); return
  fi
  if [ -n "$want_text" ] && ! grep -qF "$want_text" <<<"$ann"; then
    echo "FAIL $name: annotation missing '$want_text' (got: ${ann:-<none>})"; FAIL=$((FAIL + 1)); return
  fi
  if [ -z "$want_text" ] && [ -n "$ann" ]; then
    echo "FAIL $name: unexpected annotation: $ann"; FAIL=$((FAIL + 1)); return
  fi
  echo "ok   $name"; PASS=$((PASS + 1))
}

run() { # <name> <curl-status> <window-test> <on-timeout>
  rm -f "$ANN_FILE"; : > "$ANN_FILE"
  STUB_STATUS="$2" BUILDKITE_COMMIT=deadbeefcafe bash -c \
    "source '$HARNESS'; wait_for_healthcheck 'Payout batch' https://example.invalid 1 '$4' '$3'" \
    >/dev/null 2>&1
  echo "$?" > /tmp/.skip-test-exit
}

# 1. LB answered 5xx inside the fail-safe window -> skip, annotated, exit 0 (gp#2635's case).
run "unreachable-5xx-in-window" 500 'true' proceed
check "unreachable-5xx-in-window" 0 "deployment skipped" "$(cat /tmp/.skip-test-exit)"
grep -qF "healthcheck unreachable (HTTP 500)" "$ANN_FILE" \
  && { echo "ok   unreachable-5xx names the status"; PASS=$((PASS + 1)); } \
  || { echo "FAIL unreachable-5xx does not name HTTP 500"; FAIL=$((FAIL + 1)); }

# 2. 404 inside the window -> skip, annotated, exit 0.
run "absent-404-in-window" 404 'true' proceed
check "absent-404-in-window" 0 "healthcheck absent (HTTP 404)" "$(cat /tmp/.skip-test-exit)"

# 3. 5xx OUTSIDE the window -> proceed as before, nothing annotated, exit 0.
run "unreachable-5xx-outside-window" 500 'false' proceed
check "unreachable-5xx-outside-window" 0 "" "$(cat /tmp/.skip-test-exit)"

# 4. Job still in flight (503) to the timeout with on_timeout=skip -> skip, annotated, exit 0.
run "in-flight-timeout-skip" 503 'true' skip
check "in-flight-timeout-skip" 0 "still in flight after 3 minutes" "$(cat /tmp/.skip-test-exit)"

# 5. 200 -> deploy, no annotation.
run "healthy-200" 200 'true' proceed
check "healthy-200" 0 "" "$(cat /tmp/.skip-test-exit)"

# 6. The commit is named, so a reader can tell which change did not ship.
grep -qF "deadbeefcafe" "$ANN_FILE" 2>/dev/null || true
rm -f "$ANN_FILE"; : > "$ANN_FILE"
STUB_STATUS=500 BUILDKITE_COMMIT=deadbeefcafe bash -c \
  "source '$HARNESS'; wait_for_healthcheck 'Payout batch' https://example.invalid 1 'proceed' 'true'" >/dev/null 2>&1
grep -qF "deadbeefcafe" "$ANN_FILE" \
  && { echo "ok   annotation names the commit"; PASS=$((PASS + 1)); } \
  || { echo "FAIL annotation does not name the commit: $(cat "$ANN_FILE")"; FAIL=$((FAIL + 1)); }

rm -rf "$BIN" "$HARNESS" "$ANN_FILE" /tmp/.skip-test-exit
echo "---- $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
