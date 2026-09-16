#!/bin/bash

# Tests for run_with_retry's exhaustion and non-retryable paths.
#
# Origin: preview-app Buildkite builds 19416 and 19425 (2026-08-02) both died with
# `run_with_retry.sh: line 21: fail: command not found` / exit 127 after Nomad
# refused five connections. The retry loop worked; only its give-up path was broken,
# and it was broken in exactly the scripts that do not source nomad/common.sh.
#
# Nothing here is stubbed: run_with_retry is sourced from the shipped file and driven
# with real commands that exit with the codes we care about.
#
# Run: bash test/run_with_retry_test.sh

PASSED=0
FAILED=0

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

function ok() {
  PASSED=$((PASSED + 1))
  echo -e "${GREEN}ok${NC} $1"
}

function bad() {
  FAILED=$((FAILED + 1))
  echo -e "${RED}FAIL${NC} $1"
  if [[ -n "$2" ]]; then
    echo "     $2"
  fi
}

function assert_eq() {
  if [[ "$2" == "$3" ]]; then
    ok "$1"
  else
    bad "$1" "expected '$3', got '$2'"
  fi
}

function assert_contains() {
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    bad "$1" "expected output to contain '$3', got: $2"
  fi
}

function assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    bad "$1" "expected output NOT to contain '$3', got: $2"
  fi
}

# Runs run_with_retry in a child bash with no `fail` in scope — the situation in
# deploy.sh, delete_app.sh, restore_logs.sh and start_generic_web.sh. `delay=0` keeps
# the exhaustion test instant; logger is the trivial stand-in the real callers get
# from common.sh/nomad_proxy_functions.sh.
function drive() {
  local body="$1"
  bash -c "
    function logger() { echo \"logger: \$1\"; }
    source '$REPO_ROOT/nomad/run_with_retry.sh'
    delay=0
    $body
  " 2>&1
}

echo "== exhausting the retries =="

out=$(drive 'run_with_retry bash -c "exit 1"; echo "REACHED_AFTER=$?"')
status_out=$?

assert_contains "reports giving up after 5 attempts" "$out" "failed after 5 attempts"
assert_not_contains "does not call an undefined command" "$out" "command not found"
assert_not_contains "aborts instead of returning to the caller" "$out" "REACHED_AFTER="
assert_contains "retried the 5th time" "$out" "Attempt 5/5"
assert_not_contains "never claims a 6th attempt" "$out" "Attempt 6/5"

# The exit status is the contract callers rely on: `set -e` in deploy.sh must stop
# the deploy. 127 was the bug's signature.
drive 'run_with_retry bash -c "exit 1"' > /dev/null 2>&1
assert_eq "exits 1, not 127" "$?" "1"

echo "== a non-retryable failure =="

out=$(drive 'run_with_retry bash -c "exit 3"; echo "REACHED_AFTER=$?"')
assert_contains "names the real exit status" "$out" "exit status 3"
assert_not_contains "does not retry a non-connection error" "$out" "Attempt 2/5"
assert_not_contains "aborts on a non-retryable failure" "$out" "REACHED_AFTER="

drive 'run_with_retry bash -c "exit 3"' > /dev/null 2>&1
assert_eq "non-retryable failure also exits 1" "$?" "1"

echo "== the success paths =="

out=$(drive 'run_with_retry bash -c "exit 0"; echo "RETURNED=$?"')
assert_contains "returns 0 when the command succeeds" "$out" "RETURNED=0"
assert_not_contains "does not retry a success" "$out" "Attempt 2/5"

# Recovery: fail twice with a connection error, then succeed. This is the case the
# retry loop exists for, and it must not abort.
out=$(drive '
  attempt_file=$(mktemp)
  echo 0 > "$attempt_file"
  function flaky() {
    local n
    n=$(cat "$attempt_file")
    n=$((n + 1))
    echo "$n" > "$attempt_file"
    if [[ $n -lt 3 ]]; then return 1; fi
    return 0
  }
  run_with_retry flaky
  echo "RETURNED=$?"
  echo "ATTEMPTS=$(cat "$attempt_file")"
')
assert_contains "recovers when a later attempt succeeds" "$out" "RETURNED=0"
assert_contains "stops retrying as soon as it succeeds" "$out" "ATTEMPTS=3"
assert_not_contains "does not abort on a recovered command" "$out" "has failed after"

echo "== the retry delay is the caller's to set =="

# Pins the P2 found in review: a `local delay=5` inside run_with_retry silently
# shadows this, making every retry sleep 5s and this suite take ~51s while claiming
# to be instant. Timing is the only way to observe it.
start=$SECONDS
drive 'run_with_retry bash -c "exit 1"' > /dev/null 2>&1
elapsed=$((SECONDS - start))
if [[ $elapsed -le 3 ]]; then
  ok "honours delay=0 from the caller (${elapsed}s for 4 sleeps)"
else
  bad "honours delay=0 from the caller" "took ${elapsed}s; delay is being ignored"
fi

echo "== exit 2, a nomad evaluation with unplaceable allocations =="

# `nomad run` exits 2 when the job was accepted but its evaluation could not place
# every allocation. Only a `type = "system"` job may treat that as success: it asks
# for one allocation per node and Nomad counts every constraint-mismatched node as
# unplaceable, so the number is a property of the cluster and never reaches zero.
SPEC_DIR=$(mktemp -d)
trap 'rm -rf "$SPEC_DIR"' EXIT

cat > "$SPEC_DIR/system_job.nomad" <<'SPEC'
job "web-server-blue" {
  region = "production"
  type        = "system"
  group "web" {}
}
SPEC

cat > "$SPEC_DIR/batch_job.nomad" <<'SPEC'
job "database-migration" {
  region = "production"
  type        = "batch"
  group "migration" {}
}
SPEC

out=$(drive "run_with_retry bash -c 'exit 2' $SPEC_DIR/system_job.nomad; echo \"RETURNED=\$?\"")
assert_contains "a system job tolerates exit 2" "$out" "RETURNED=0"
assert_contains "says why it continued" "$out" "unplaceable allocations"
assert_not_contains "does not retry a tolerated exit 2" "$out" "Attempt 2/5"
assert_not_contains "does not abort a tolerated exit 2" "$out" "not retryable"

# The whole point of scoping this: a migration or setup_app that never got a node is
# a failed deploy, and must not report success.
out=$(drive "run_with_retry bash -c 'exit 2' $SPEC_DIR/batch_job.nomad; echo \"REACHED_AFTER=\$?\"")
assert_contains "a batch job still aborts on exit 2" "$out" "exit status 2"
assert_not_contains "a batch job does not reach the caller" "$out" "REACHED_AFTER="

drive "run_with_retry bash -c 'exit 2' $SPEC_DIR/batch_job.nomad" > /dev/null 2>&1
assert_eq "a batch job's exit 2 still exits 1" "$?" "1"

# Fail closed. `nomad stop app_<name>` passes no spec, and a spec that has been
# removed or never rendered must not be read as permission to continue.
out=$(drive 'run_with_retry bash -c "exit 2" stop -yes app_something; echo "REACHED_AFTER=$?"')
assert_contains "no spec argument stays strict" "$out" "exit status 2"
assert_not_contains "no spec argument does not reach the caller" "$out" "REACHED_AFTER="

out=$(drive "run_with_retry bash -c 'exit 2' $SPEC_DIR/absent.nomad; echo \"REACHED_AFTER=\$?\"")
assert_contains "an unreadable spec stays strict" "$out" "exit status 2"
assert_not_contains "an unreadable spec does not reach the caller" "$out" "REACHED_AFTER="

# Tolerance is about exit 2 only; a connection error against a system job still gets
# the full retry budget and still aborts when it runs out.
out=$(drive "run_with_retry bash -c 'exit 1' $SPEC_DIR/system_job.nomad; echo \"REACHED_AFTER=\$?\"")
assert_contains "a system job still retries a connection error" "$out" "Attempt 5/5"
assert_not_contains "a system job still aborts an exhausted retry" "$out" "REACHED_AFTER="

echo "== the shipped specs this rule applies to =="

# Pins which real jobs are affected. If a spec's type changes, or a new system job
# joins a deploy, that is a deliberate change to what tolerates exit 2 and this
# should be the thing that says so.
# The specs are committed as .erb and rendered to .nomad by run_job, and the helper
# only looks at .nomad arguments — so copy to the rendered name the way a deploy sees
# it. `type` is never templated, so the copy is faithful for this purpose.
function assert_job_type() {
  local spec="$REPO_ROOT/$1" expected="$2" detected rendered
  if [[ ! -f "$spec" ]]; then
    bad "$1 exists" "no such file"
    return
  fi
  rendered="$SPEC_DIR/$(basename "${1%.erb}")"
  cp "$spec" "$rendered"
  if bash -c "source '$REPO_ROOT/nomad/run_with_retry.sh'; run_with_retry_job_is_system '$rendered'"; then
    detected="system"
  else
    detected="not-system"
  fi
  assert_eq "$1 is $expected" "$detected" "$expected"
}

# The preview-app deploy: only nginx is a system job.
assert_job_type "nomad/staging/deploy_branch/branch_app_nginx.nomad.erb" "system"
assert_job_type "nomad/staging/deploy_branch/setup_app.nomad.erb" "not-system"
assert_job_type "nomad/staging/deploy_branch/database_migration.nomad.erb" "not-system"
assert_job_type "nomad/staging/deploy_branch/scale_up.nomad.erb" "not-system"
assert_job_type "nomad/staging/deploy_branch/setup_deployment_environment.nomad.erb" "not-system"

# The production deploy: anycable-rpc is what #51 stopped it on, and the web and
# sidekiq jobs report the same way.
assert_job_type "nomad/production/anycable_rpc.nomad.erb" "system"
assert_job_type "nomad/production/web_server_blue.nomad.erb" "system"
assert_job_type "nomad/production/sidekiq_worker.nomad.erb" "system"
assert_job_type "nomad/production/post_deployment.nomad.erb" "not-system"

echo
echo "passed: $PASSED  failed: $FAILED"
[[ $FAILED -eq 0 ]]
