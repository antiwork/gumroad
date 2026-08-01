#!/usr/bin/env bash
# Verifies the FINAL long-running-job confirmation is fail-safe, not fail-open.
#
# Greptile's P1: the confirmation broke out of the loop for every status other than 503,
# so 404 and curl's 000 (endpoint unreachable) reached the deploy gate as if the app had
# answered "nothing in flight". Runs the real confirmation block from
# .buildkite/scripts/deploy_production.sh with the healthcheck and the waits stubbed.
set -uo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/.buildkite/scripts/deploy_production.sh"

run_case() {
  local status="$1" inside_window="$2"
  # Slice out the confirmation loop verbatim so the harness cannot drift from the script.
  local block
  block=$(sed -n '/^CONFIRMATION_ROUNDS=/,/^done$/p' "$SCRIPT")

  bash <<EOF
set -uo pipefail
logger() { printf 'LOG %s\n' "\$*"; }
poll_healthcheck() { printf '%s\n' "$status"; }
run_healthcheck_waits() { :; }
LONG_RUNNING_JOBS_HEALTHCHECK_URL=stub
LONG_RUNNING_FAILSAFE_WINDOW_TEST='$inside_window'
$block
printf 'DEPLOYMENT_GATE_REACHED\n'
EOF
}

for status in 200 404 000 502; do
  for window in true false; do
    label="status=$status inside_failsafe_window=$window"
    out=$(run_case "$status" "$window")
    if printf '%s' "$out" | grep -q DEPLOYMENT_GATE_REACHED; then
      echo "$label -> DEPLOYS"
    else
      echo "$label -> SKIPS"
    fi
    printf '%s\n' "$out" | sed 's/^/    /'
  done
done
