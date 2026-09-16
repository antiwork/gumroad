#!/bin/bash

# Tests for wait_for_db_migrate and the migration phase's failure path.
#
# What is real and what is stubbed: the functions under test are sourced from the
# shipped nomad/common.sh and nomad/migration_fast_path.sh, unmodified. Only the two
# things that talk to the outside world are replaced -- `curl` (Consul) and
# `nomad_insecure_wrapper` (Nomad) -- so what the tests exercise is the real control
# flow, not a re-implementation of it.
#
# Run: bash test/db_migrate_wait_test.sh

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

function fail() {
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
    fail "$1" "expected '$3', got '$2'"
  fi
}

function assert_contains() {
  if [[ "$2" == *"$3"* ]]; then
    ok "$1"
  else
    fail "$1" "expected output to contain '$3'"
  fi
}

function assert_not_contains() {
  if [[ "$2" != *"$3"* ]]; then
    ok "$1"
  else
    fail "$1" "expected output NOT to contain '$3'"
  fi
}

# ---------------------------------------------------------------------------
# Harness
# ---------------------------------------------------------------------------
#
# Each case runs in its own subshell with a fresh scenario, because the functions
# under test loop on state that the stubs mutate.
#
# The stubs are driven by files rather than variables so that the values survive the
# command substitutions the real code uses ($(...) runs in a subshell, so a stub
# cannot report back through a shell variable).

function harness() {
  SCENARIO_DIR=$(mktemp -d)
  export SCENARIO_DIR

  # Consul: the key exists once PUBLISH_AFTER polls have been served. -1 means never.
  echo "-1" > "$SCENARIO_DIR/publish_after"
  echo "0"  > "$SCENARIO_DIR/consul_polls"

  # Nomad: which allocation table to serve, or how `nomad job status` fails.
  echo "active" > "$SCENARIO_DIR/job_state"

  DEPLOY_TAG="production-abc123def456"
  REVISION="abc123def456"

  function logger() {
    echo "LOG: $1"
  }

  # Stub Consul. The real code calls `curl -s http://localhost:8500/v1/kv/<key>` and
  # greps for the deploy tag, so the stub prints a Consul-shaped body containing the
  # key name, or nothing.
  function curl() {
    local polls publish
    polls=$(cat "$SCENARIO_DIR/consul_polls")
    publish=$(cat "$SCENARIO_DIR/publish_after")
    polls=$((polls + 1))
    echo "$polls" > "$SCENARIO_DIR/consul_polls"

    if [[ "$publish" -ge 0 && "$polls" -gt "$publish" ]]; then
      echo "[{\"Key\":\"database_version_${DEPLOY_TAG}\",\"Value\":\"MjAyNg==\"}]"
    fi
  }

  # Stub Nomad. Emits real-shaped `nomad job status` output, including the header
  # widths and the multi-word Created/Modified values that make column positions
  # unusable. `aaaa1111` is an allocation left behind by an EARLIER deploy (Nomad
  # keeps terminal batch allocations until GC); `bbbb2222` is this deploy's.
  function nomad_insecure_wrapper() {
    local state
    state=$(cat "$SCENARIO_DIR/job_state")

    local header='Allocations\nID        Node ID   Task Group  Version  Desired  Status    Created     Modified\n'

    case "$state" in
      unreadable)
        # An unreachable API: non-zero, and nothing we can interpret.
        echo "Error querying job status: Get \"http://127.0.0.1:4646/v1/job/database_migration\": dial tcp: connection refused"
        return 1
        ;;
      job_not_registered)
        # Nothing has ever run this job. A known-empty answer, not an unreadable one.
        echo 'No job(s) with prefix or id "database_migration" found'
        return 1
        ;;
      no_allocs_section)
        # Output whose shape we do not recognise.
        printf 'ID = database_migration\nStatus = pending\n'
        ;;
      no_allocs_yet)
        # Job submitted, Nomad has not created this deploy's allocation yet.
        printf "$header"
        ;;
      active)
        printf "$header"
        printf 'bbbb2222  9c1d2e3f  migration   7        run      running   10s ago     5s ago\n'
        ;;
      complete)
        printf "$header"
        printf 'bbbb2222  9c1d2e3f  migration   7        run      complete  2m30s ago   10s ago\n'
        ;;
      failed)
        printf "$header"
        printf 'bbbb2222  9c1d2e3f  migration   7        run      failed    2m30s ago   10s ago\n'
        ;;
      full_uuid_failed)
        # Nomad prints short ids in the Allocations table, but `-verbose` and some
        # versions print the full UUID. Both are allocation rows.
        printf "$header"
        printf 'bbbb2222-3333-4444-5555-666677778888  9c1d2e3f  migration   7        run      failed    30s ago     2s ago\n'
        ;;
      prior_settled)
        # ONLY the earlier deploy's finished allocation. This is what Nomad reports in
        # the seconds after `nomad job run` and before the new allocation appears.
        printf "$header"
        printf 'aaaa1111  9c1d2e3f  migration   6        run      complete  1h2m ago    1h1m ago\n'
        ;;
      prior_settled_and_active)
        printf "$header"
        printf 'bbbb2222  9c1d2e3f  migration   7        run      running   10s ago     5s ago\n'
        printf 'aaaa1111  9c1d2e3f  migration   6        run      complete  1h2m ago    1h1m ago\n'
        ;;
      prior_settled_and_failed)
        printf "$header"
        printf 'bbbb2222  9c1d2e3f  migration   7        run      failed    30s ago     2s ago\n'
        printf 'aaaa1111  9c1d2e3f  migration   6        run      complete  1h2m ago    1h1m ago\n'
        ;;
    esac
    return 0
  }

  # No real waiting. The loop's own elapsed counter still advances, so timeout cases
  # terminate; they just do not take wall-clock time.
  function sleep() { :; }
}

function extract_functions() {
  # Everything from the DB_MIGRATE_TIMEOUT_SECONDS default through the end of
  # wait_for_db_migrate: the pieces under test and nothing else.
  awk '/^DB_MIGRATE_TIMEOUT_SECONDS=/{on=1} on{print} on && /^}$/ && seen_wait{exit} /^function wait_for_db_migrate/{seen_wait=1}' \
    "$REPO_ROOT/nomad/common.sh"
}

# One case = snapshot the allocations the job has BEFORE submission, then serve the
# post-submission state and run the wait. That ordering is the real deploy's
# (snapshot_migration_allocs, run_job, wait_for_db_migrate), and it is the ordering
# the whole scoping argument depends on, so the tests go through it rather than
# setting the baseline by hand.
function run_case_with_baseline() {
  local baseline_state=$1 job_state=$2 publish_after=$3 timeout=${4:-20}
  (
    harness
    eval "$(extract_functions)"
    echo "$baseline_state" > "$SCENARIO_DIR/job_state"
    snapshot_migration_allocs
    echo "$job_state" > "$SCENARIO_DIR/job_state"
    echo "$publish_after" > "$SCENARIO_DIR/publish_after"
    wait_for_db_migrate "$timeout"
    echo "EXIT=$?"
  ) 2>&1
}

# The common shape: a job whose earlier allocations, if any, have already been
# accounted for. Baseline is read from the same state, so any allocation the wait
# then sees in `prior_*` scenarios is a retained one it must ignore.
function run_case() {
  local job_state=$1 publish_after=$2 timeout=${3:-20}
  local baseline_state=$job_state

  # For the states that represent "this deploy's allocation exists", the baseline
  # taken before submission is the job with no allocation of ours yet.
  case "$job_state" in
    active|complete|failed|full_uuid_failed|no_allocs_yet) baseline_state=no_allocs_yet ;;
    prior_settled|prior_settled_and_active|prior_settled_and_failed) baseline_state=prior_settled ;;
  esac

  run_case_with_baseline "$baseline_state" "$job_state" "$publish_after" "$timeout"
}

echo "== wait_for_db_migrate =="

# The happy path, unchanged behaviour: the key appears and the wait returns 0.
out=$(run_case active 2)
assert_contains "publishes the version -> success log" "$out" "db:migrate has completed successfully"
assert_contains "publishes the version -> exit 0" "$out" "EXIT=0"

# THE BUG THIS CHANGE FIXES. Job finished, no version published. Before the change
# this looped forever; now it returns non-zero with an actionable message.
out=$(run_case failed -1)
assert_contains "failed job -> reports failure" "$out" "db:migrate FAILED"
assert_contains "failed job -> says nothing was deployed" "$out" "Nothing has been deployed"
assert_contains "failed job -> points at the migration log" "$out" "logs.sh"
assert_contains "failed job -> exit 1" "$out" "EXIT=1"
assert_not_contains "failed job -> does not claim success" "$out" "completed successfully"

# A job whose allocation is Complete but which still published nothing is the same
# failure: docker/web/database_migration.sh is `set -e`, so a non-zero rake exit ends
# the allocation without the Consul write.
out=$(run_case complete -1)
assert_contains "complete-but-unpublished -> reports failure" "$out" "db:migrate FAILED"
assert_contains "complete-but-unpublished -> exit 1" "$out" "EXIT=1"

# An allocation row identified by its FULL UUID rather than the short id. Both shapes
# have to be recognised as allocation rows; if the id match silently stops matching,
# every row vanishes, the counts read 0 active / 0 settled, and the failure detection
# turns itself off without saying so.
out=$(run_case full_uuid_failed -1)
assert_contains "full-UUID allocation row -> still detected as failed" "$out" "db:migrate FAILED"
assert_contains "full-UUID allocation row -> exit 1" "$out" "EXIT=1"

# The allocation-row match must not use an awk interval expression (`[0-9a-f]{8}`).
# Interval expressions are optional in POSIX awk and older mawk builds treat the
# braces literally, so the pattern would match nothing -- and matching nothing is
# silent: no allocation rows, counts of 0/0, and the failure detection this change
# exists for switched off with no message. The functional case above cannot catch that
# on a host whose awk does support intervals, so the constraint is asserted directly.
interval_usage=$(grep -c '\[0-9a-f\]{' "$REPO_ROOT/nomad/common.sh" | tr -d ' ')
assert_eq "allocation id match avoids awk interval expressions" "$interval_usage" "0"

# The race the second read exists for: the allocation settles in the same iteration
# the version lands. Must be read as success, not as a failed migration.
out=$(run_case complete 1)
assert_contains "settles as it publishes -> success" "$out" "completed successfully"
assert_contains "settles as it publishes -> exit 0" "$out" "EXIT=0"
assert_not_contains "settles as it publishes -> no false failure" "$out" "db:migrate FAILED"

# The window between `nomad job run` and Nomad creating allocations: the table is
# there with no row for this deploy. active==0 there, so without the `settled > 0`
# condition this would report a failure before the migration had even started.
out=$(run_case no_allocs_yet 3)
assert_contains "no allocations yet -> waits, then succeeds" "$out" "completed successfully"
assert_not_contains "no allocations yet -> not called a failure" "$out" "db:migrate FAILED"

# THE OTHER WAY TO GET THIS WRONG, and what the allocation scoping exists for. Nomad
# keeps terminal batch allocations until they are garbage collected, so the previous
# deploy's finished migration is still listed under this job. Judged from job-wide
# totals it looks exactly like "this deploy's migration finished without publishing",
# and the deploy aborts in its first poll -- before its own migration has started.
out=$(run_case prior_settled -1 6)
assert_not_contains "retained allocation from an earlier deploy -> not a failure" "$out" "db:migrate FAILED"
assert_contains "retained allocation from an earlier deploy -> keeps waiting" "$out" "TIMED OUT"

out=$(run_case prior_settled 3)
assert_contains "retained allocation, then this migration publishes -> success" "$out" "completed successfully"
assert_contains "retained allocation, then this migration publishes -> exit 0" "$out" "EXIT=0"

# Retained allocation alongside this deploy's own: the retained one must not make the
# running one look settled.
out=$(run_case prior_settled_and_active -1 6)
assert_contains "retained + this deploy running -> only the ceiling stops it" "$out" "TIMED OUT"
assert_contains "retained + this deploy running -> counts only our allocation" "$out" "1 allocation(s) still active"
assert_not_contains "retained + this deploy running -> not a failure" "$out" "db:migrate FAILED"

# And the retained one must not mask a real failure of ours either.
out=$(run_case prior_settled_and_failed -1)
assert_contains "retained + this deploy failed -> reports failure" "$out" "db:migrate FAILED"
assert_contains "retained + this deploy failed -> exit 1" "$out" "EXIT=1"

# A job Nomad has never heard of is a KNOWN empty baseline, not an unreadable one:
# the first deploy after this lands, and any freshly built cluster, registers the job
# for the first time and must still get failure detection.
out=$(run_case_with_baseline job_not_registered failed -1)
assert_contains "first-ever run of the job -> failure still detected" "$out" "db:migrate FAILED"
assert_contains "first-ever run of the job -> exit 1" "$out" "EXIT=1"

# If the pre-submission baseline could not be read, retained allocations cannot be
# told apart from new ones, so the failure detection has to switch itself off rather
# than risk aborting a healthy deploy. Both an unreachable Nomad and output we cannot
# parse have to behave that way.
out=$(run_case_with_baseline unreadable prior_settled -1 6)
assert_contains "unknown baseline -> failure detection disabled, warns" "$out" "will not be detected"
assert_not_contains "unknown baseline -> retained allocation is not read as our failure" "$out" "db:migrate FAILED"
assert_contains "unknown baseline -> falls back to the ceiling" "$out" "TIMED OUT"

out=$(run_case_with_baseline no_allocs_section prior_settled -1 6)
assert_not_contains "unparseable baseline -> retained allocation is not read as our failure" "$out" "db:migrate FAILED"
assert_contains "unparseable baseline -> falls back to the ceiling" "$out" "TIMED OUT"

# An unreadable Nomad must never look like a finished job.
out=$(run_case_with_baseline no_allocs_yet unreadable 4)
assert_contains "unreadable Nomad -> keeps waiting, then succeeds" "$out" "completed successfully"
assert_not_contains "unreadable Nomad -> not called a failure" "$out" "db:migrate FAILED"

out=$(run_case_with_baseline no_allocs_yet unreadable -1 6)
assert_contains "unreadable Nomad forever -> times out" "$out" "TIMED OUT"
assert_contains "unreadable Nomad forever -> says status unreadable" "$out" "could not be read"
assert_contains "unreadable Nomad forever -> exit 1" "$out" "EXIT=1"

# Output we cannot parse is also "cannot tell", not "finished".
out=$(run_case_with_baseline no_allocs_yet no_allocs_section -1 6)
assert_contains "unparseable status -> times out rather than failing early" "$out" "TIMED OUT"
assert_not_contains "unparseable status -> not called a failure" "$out" "db:migrate FAILED"

# A genuinely long migration is not aborted by the failure detection -- only by the
# ceiling, which is hours.
out=$(run_case active -1 6)
assert_contains "long-running job -> only the ceiling stops it" "$out" "TIMED OUT"
assert_contains "long-running job -> names the active allocation" "$out" "1 allocation(s) still active"
assert_contains "long-running job -> exit 1" "$out" "EXIT=1"

out=$(run_case active 4 100)
assert_contains "long-running job that eventually publishes -> success" "$out" "completed successfully"
assert_contains "long-running job that eventually publishes -> exit 0" "$out" "EXIT=0"

# The default ceiling is generous on purpose: pt-online-schema-change on purchases or
# users legitimately runs for hours, so it must not be a number that could abort one.
out=$(
  harness
  eval "$(extract_functions)"
  echo "CEILING=$DB_MIGRATE_TIMEOUT_SECONDS"
)
assert_contains "default ceiling is 3 hours" "$out" "CEILING=10800"

echo
echo "== deploy_database_migrations propagates the failure =="

# The failure has to reach gr_deploy, and record_migrated_revision must NOT run: it
# records the revision as migrated, which would let a later deploy of the same
# revision take the fast path and skip the migration that never ran.
mig_case() {
  local wait_rc=$1
  (
    function logger() { echo "LOG: $1"; }
    function run_job() { echo "RAN_JOB=$1"; }
    function snapshot_migration_allocs() { echo "SNAPSHOT_TAKEN"; }
    function migration_fast_path_available() { return 1; }
    function publish_schema_version_for_fast_path() { return 1; }
    function wait_for_db_migrate() { return "$wait_rc"; }
    function record_migrated_revision() { echo "RECORDED_MIGRATED_REVISION"; }

    eval "$(awk '/^function deploy_database_migrations/,/^}$/' "$REPO_ROOT/nomad/migration_fast_path.sh")"

    deploy_database_migrations
    echo "EXIT=$?"
  ) 2>&1
}

out=$(mig_case 1)
assert_contains "failed wait -> ran the migration job" "$out" "RAN_JOB=database_migration"
assert_contains "failed wait -> deploy_database_migrations returns non-zero" "$out" "EXIT=1"
assert_not_contains "failed wait -> does NOT record the revision as migrated" "$out" "RECORDED_MIGRATED_REVISION"

# Ordering, not just presence: the baseline of pre-existing allocations is only
# meaningful if it is taken BEFORE the job is submitted. Afterwards this deploy's own
# allocation would be in the baseline and excluded from its own failure detection,
# which silently restores the original hanging bug.
snapshot_line=$(echo "$out" | grep -n 'SNAPSHOT_TAKEN' | cut -d: -f1)
run_job_line=$(echo "$out" | grep -n 'RAN_JOB=database_migration' | cut -d: -f1)
if [[ -n "$snapshot_line" && -n "$run_job_line" && "$snapshot_line" -lt "$run_job_line" ]]; then
  ok "snapshots existing allocations BEFORE submitting the job"
else
  fail "snapshots existing allocations BEFORE submitting the job" \
    "snapshot at line '${snapshot_line:-none}', run_job at line '${run_job_line:-none}'"
fi

out=$(mig_case 0)
assert_contains "successful wait -> records the revision as migrated" "$out" "RECORDED_MIGRATED_REVISION"
assert_contains "successful wait -> returns 0" "$out" "EXIT=0"

echo
echo "== gr_deploy aborts before deploying application code =="

# The whole point of failing: no application code ships behind a migration that did
# not run. This drives the real gr_deploy guard with the surrounding deploy stubbed.
gr_case() {
  local mig_rc=$1
  (
    set -e
    DEPLOY_TAG="production-abc123def456"
    function logger() { echo "LOG: $1"; }
    function deploy_database_migrations() { return "$mig_rc"; }
    function run_job() { echo "RAN_JOB=$1"; }
    function scale_up_web_server_clusters() { echo "RAN=scale_up"; }
    function deploy_to_web_servers() { echo "RAN=web_deploy"; }
    function create_release_tag() { echo "RAN=release_tag"; }
    function production_deployment() { return 0; }

    # The guard as shipped, extracted from gr_deploy so the test cannot drift from it.
    eval "$(awk '/A failed migration must stop the deploy/,/^  run_job post_deployment$/' "$REPO_ROOT/nomad/common.sh")"
    create_release_tag
    echo "REACHED_END=1"
  ) 2>&1
  echo "EXIT=$?"
}

out=$(gr_case 1)
assert_contains "migration failure -> aborts with a clear reason" "$out" "Aborting the deploy"
assert_contains "migration failure -> says no code was deployed" "$out" "No application code has been deployed"
assert_not_contains "migration failure -> no web deploy" "$out" "RAN=web_deploy"
assert_not_contains "migration failure -> no worker jobs" "$out" "RAN_JOB=sidekiq_worker"
assert_not_contains "migration failure -> no release tag" "$out" "RAN=release_tag"
assert_contains "migration failure -> non-zero exit" "$out" "EXIT=1"

out=$(gr_case 0)
assert_contains "migration success -> deploys the workers" "$out" "RAN_JOB=sidekiq_worker"
assert_contains "migration success -> deploys the web clusters" "$out" "RAN=web_deploy"
assert_contains "migration success -> tags the release" "$out" "RAN=release_tag"
assert_contains "migration success -> exits 0" "$out" "EXIT=0"

echo
echo "PASSED=$PASSED FAILED=$FAILED"
[[ "$FAILED" -eq 0 ]]
