#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_production.sh: $1${NC}"
}

SKIP_DEPLOY=10

PAYOUT_HEALTHCHECK_URL="https://gumroad.com/healthcheck/payouts"
LONG_RUNNING_JOBS_HEALTHCHECK_URL="https://gumroad.com/healthcheck/long_running_jobs"

poll_healthcheck() {
  local status
  # On a connection failure curl already writes "000" to stdout, so the fallback is only
  # for the case where curl writes nothing at all.
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$1") || status="000"
  printf '%s\n' "$status"
}

# Deploys wait while work a deploy would destroy is ACTUALLY running, by asking the app
# rather than guessing from the clock. Jobs a deploy must not interrupt register a token in
# Redis while they run (see DeployBlockingJobTracking) and the matching healthcheck answers
# 503 for as long as any of them is registered.
#
# wait_for_healthcheck <label> <url> <max attempts> <on-timeout: proceed|skip> <fail-safe window test>
#
# Polls every 3 minutes. Meanings of the answers:
#   200 -> nothing in flight, deploy now.
#   503 -> something is in flight, keep waiting.
#   404 -> the app in production does not serve this endpoint at all. Treated like any other
#     answer we cannot interpret (below), just with its own log line, because the reasons a
#     live endpoint would start 404ing are worth spotting in the deploy log: a route renamed
#     or removed while the tracking code is still in the jobs, a web-tier-only rollback while
#     the workers stay on the new image, or an edge/CDN 404.
#   anything else (unreachable, 5xx from the LB, ...) -> we cannot tell, so fall back to the
#     conservative clock window this check replaced: skip the deploy if we are inside it,
#     proceed if we are not. A broken healthcheck can then never be worse than the old
#     time-based behaviour.
#
# The fail-safe window test is a shell snippet evaluated with `eval`; it should succeed when
# the current time is inside the window.
#
# Every return path reports how many 3-minute sleeps it actually burned, in WAIT_SLEEPS_USED and
# (when a 6th argument is given) in that file, so a caller that may enter the same wait more than
# once can charge all of them against ONE budget. See LONG_RUNNING_ATTEMPTS_LEFT below.
wait_for_healthcheck() {
  local label="$1" url="$2" max_attempts="$3" on_timeout="$4" failsafe_window_test="$5"
  local sleeps_file="$6"
  local attempt hc_status

  WAIT_SLEEPS_USED=0
  record_sleeps_used() {
    [ -n "$sleeps_file" ] || return 0
    printf '%s\n' "$WAIT_SLEEPS_USED" > "$sleeps_file.tmp"
    mv "$sleeps_file.tmp" "$sleeps_file"
  }

  if [ "$max_attempts" -le 0 ]; then
    record_sleeps_used
    if [ "$on_timeout" = "skip" ]; then
      logger "$label wait budget exhausted — skipping deployment (the change ships with the next push, or click require-approval to force it)"
      return "$SKIP_DEPLOY"
    fi
    logger "WARNING: $label wait budget exhausted — proceeding with deploy anyway (this means it is unusually slow and worth a look)"
    return 0
  fi

  for attempt in $(seq 1 "$max_attempts"); do
    hc_status=$(poll_healthcheck "$url")
    if [ "$hc_status" = "200" ]; then
      record_sleeps_used
      return 0
    elif [ "$hc_status" = "503" ]; then
      logger "$label in flight (healthcheck 503) — waiting 3 minutes (attempt $attempt/$max_attempts)"
      sleep 180
      WAIT_SLEEPS_USED=$((WAIT_SLEEPS_USED + 1))
    elif [ "$hc_status" = "404" ]; then
      record_sleeps_used
      if eval "$failsafe_window_test"; then
        logger "$label healthcheck absent (HTTP 404) inside the fail-safe window — skipping deployment"
        return "$SKIP_DEPLOY"
      fi
      logger "$label healthcheck absent (HTTP 404) outside the fail-safe window — proceeding"
      return 0
    else
      record_sleeps_used
      if eval "$failsafe_window_test"; then
        logger "$label healthcheck unreachable (HTTP $hc_status) inside the fail-safe window — skipping deployment"
        return "$SKIP_DEPLOY"
      fi
      logger "$label healthcheck unreachable (HTTP $hc_status) outside the fail-safe window — proceeding"
      return 0
    fi
  done

  record_sleeps_used
  if [ "$on_timeout" = "skip" ]; then
    logger "$label still in flight after $((max_attempts * 3)) minutes — skipping deployment (the change ships with the next push, or click require-approval to force it)"
    return "$SKIP_DEPLOY"
  fi
  logger "WARNING: $label still in flight after $((max_attempts * 3)) minutes — proceeding with deploy anyway (this means it is unusually slow and worth a look)"
  return 0
}

# The clock window the long-running check falls back to when it cannot read the endpoint.
# Named because both the wait and the final confirmation have to agree on it.
LONG_RUNNING_FAILSAFE_WINDOW_TEST='[ "$(date -u +%-H)" -le 5 ] || { [ "$(date -u +%-H)" -ge 8 ] && [ "$(date -u +%-H)" -le 13 ]; }'

# Long-running non-payout jobs — the monthly/quarterly finance and tax reports and the
# daily instant payouts (see LongRunningJobTracking). These are NOT safe to
# interrupt: they hold no checkpoint, so a recycled worker means the run starts over, and
# killed runs of these are how finance reports have silently gone missing. So we wait longer
# (up to 2 hours, the slowest of them is the Canada sales report at well over an hour) and,
# if one is still running at the end of that, skip this deploy rather than kill the report.
#
# Note this check runs on EVERY deploy, not only overnight ones, and it skips rather than
# proceeds — so a manual mid-day re-run of one of these reports will make that deploy wait
# and then drop. That is the intended trade (never kill a report), and the skipped change
# ships with the next push or via require-approval; the bound on how long a hung job can keep
# skipping deploys is LongRunningJobTracking::IN_FLIGHT_ENTRY_TTL.
#
# Fail-safe window (used ONLY when the healthcheck cannot be reached): the UTC hours these
# jobs are actually SCHEDULED for, plus ~2h of runtime headroom. Read straight off
# config/sidekiq_schedule.yml, which is written in UTC — the schedule is not an ET
# midnight-6am block, so testing ET hours here would leave most of it uncovered:
#   UTC 00:00 outstanding balances CSV
#   UTC 01:00 monthly financial reports (fans out the Canada sales report, 1-2h)
#   UTC 02:00 YTD sales report   UTC 03:00 TaxJar upload, India sales report
#   UTC 08:00 daily instant payouts
#   UTC 10:00 quarterly financial reports (VAT + per-country sales reports)
#   UTC 11:00 finances / deferred refunds / Stripe balance summaries reports
# => hours 00-05 and 08-13. Outside those we proceed, because nothing that registers here
# is scheduled to be running.

# The long-running blocker can be entered more than once (the confirmation loop below re-waits
# when it goes busy again), so all of those entries share ONE attempt budget instead of each
# getting a fresh 40. A per-entry budget is what killed build #18755 in a different disguise:
# 40 attempts x 3 min x 5 rounds is 600 minutes of legal waiting inside a 240-minute step, so a
# deploy that genuinely re-waited was killed as `timed_out` instead of exiting 0 on its own skip
# path. Spent attempts come back from wait_for_healthcheck via WAIT_SLEEPS_USED.
LONG_RUNNING_MAX_ATTEMPTS=40
LONG_RUNNING_ATTEMPTS_LEFT=$LONG_RUNNING_MAX_ATTEMPTS

run_healthcheck_waits() {
  local tmpdir payout_pid long_pid remaining rc long_sleeps
  tmpdir=$(mktemp -d)

  (
    set +e
    wait_for_healthcheck "Payout batch" "$PAYOUT_HEALTHCHECK_URL" 15 proceed \
      '[ "$(date -u +%u)" -ge 2 ] && [ "$(date -u +%u)" -le 5 ] && [ "$(date -u +%H)" -eq 10 ]'
    rc=$?
    printf '%s\n' "$rc" > "$tmpdir/payout.rc.tmp"
    mv "$tmpdir/payout.rc.tmp" "$tmpdir/payout.rc"
    exit 0
  ) &
  payout_pid=$!

  (
    set +e
    wait_for_healthcheck "Long-running job" "$LONG_RUNNING_JOBS_HEALTHCHECK_URL" \
      "$LONG_RUNNING_ATTEMPTS_LEFT" skip \
      "$LONG_RUNNING_FAILSAFE_WINDOW_TEST" "$tmpdir/long.sleeps"
    rc=$?
    printf '%s\n' "$rc" > "$tmpdir/long.rc.tmp"
    mv "$tmpdir/long.rc.tmp" "$tmpdir/long.rc"
    exit 0
  ) &
  long_pid=$!

  remaining=2
  while [ "$remaining" -gt 0 ]; do
    for name in payout long; do
      [ -f "$tmpdir/$name.seen" ] && continue
      [ -f "$tmpdir/$name.rc" ] || continue
      rc=$(cat "$tmpdir/$name.rc")
      case "$rc" in ''|*[!0-9]*) continue ;; esac
      touch "$tmpdir/$name.seen"
      remaining=$((remaining - 1))
      if [ "$rc" -eq "$SKIP_DEPLOY" ]; then
        kill "$payout_pid" "$long_pid" 2>/dev/null || true
        wait "$payout_pid" "$long_pid" 2>/dev/null || true
        rm -rf "$tmpdir"
        exit 0
      elif [ "$rc" -ne 0 ]; then
        kill "$payout_pid" "$long_pid" 2>/dev/null || true
        wait "$payout_pid" "$long_pid" 2>/dev/null || true
        rm -rf "$tmpdir"
        exit "$rc"
      fi
    done
    [ "$remaining" -gt 0 ] && sleep 1
  done

  wait "$payout_pid" "$long_pid" 2>/dev/null || true
  # Charge the long-running wait's spent attempts to the shared budget before returning, so the
  # confirmation loop's re-waits cannot restart from a full 40.
  if [ -f "$tmpdir/long.sleeps" ]; then
    long_sleeps=$(cat "$tmpdir/long.sleeps")
    case "$long_sleeps" in ''|*[!0-9]*) long_sleeps=0 ;; esac
    LONG_RUNNING_ATTEMPTS_LEFT=$((LONG_RUNNING_ATTEMPTS_LEFT - long_sleeps))
    [ "$LONG_RUNNING_ATTEMPTS_LEFT" -lt 0 ] && LONG_RUNNING_ATTEMPTS_LEFT=0
  fi
  rm -rf "$tmpdir"
}

# A wait that finishes early goes stale while the other one is still busy: a protected job
# starting in that window would never be seen again before the deploy. Serially the
# long-running check ran last, so it was always fresh at deploy time — restore that by
# rechecking it after the parallel waits drain and re-waiting if it went busy again. Only
# the long-running blocker gets this treatment, and only IT re-waits on retries: payout
# staleness is accepted by design (an interrupted slice is re-run by Sidekiq, hence
# proceed-on-timeout), and re-entering the payout wait each round would multiply its
# 45-minute budget by the confirmation rounds — up to 225 extra minutes against the
# deploy step's 240-minute allowance.
# 503 loops. A confirmation poll that cannot be read (404, LB 5xx, curl's 000) is NOT
# clearance: this is a fresh read taken after the waits cleared, so it gets the same
# fail-safe-window semantics the waits use — skip inside the window, proceed outside it.
# Only 200 proceeds unconditionally.
CONFIRMATION_ROUNDS=5
confirmation_round=1
run_healthcheck_waits
while true; do
  long_status=$(poll_healthcheck "$LONG_RUNNING_JOBS_HEALTHCHECK_URL")
  if [ "$long_status" = "200" ]; then
    break
  fi
  if [ "$long_status" != "503" ]; then
    if eval "$LONG_RUNNING_FAILSAFE_WINDOW_TEST"; then
      logger "Long-running job confirmation unreadable (HTTP $long_status) inside the fail-safe window — skipping deployment"
      exit 0
    fi
    logger "Long-running job confirmation unreadable (HTTP $long_status) outside the fail-safe window — proceeding"
    break
  fi
  if [ "$confirmation_round" -ge "$CONFIRMATION_ROUNDS" ]; then
    logger "Long-running job busy again on every confirmation round — skipping deployment (the change ships with the next push, or click require-approval to force it)"
    exit 0
  fi
  logger "Long-running job busy again after the waits cleared — waiting again (confirmation round $confirmation_round/$CONFIRMATION_ROUNDS, $LONG_RUNNING_ATTEMPTS_LEFT of $LONG_RUNNING_MAX_ATTEMPTS wait attempts left)"
  confirmation_round=$((confirmation_round + 1))
  long_rc=0
  wait_for_healthcheck "Long-running job" "$LONG_RUNNING_JOBS_HEALTHCHECK_URL" \
    "$LONG_RUNNING_ATTEMPTS_LEFT" skip \
    "$LONG_RUNNING_FAILSAFE_WINDOW_TEST" || long_rc=$?
  LONG_RUNNING_ATTEMPTS_LEFT=$((LONG_RUNNING_ATTEMPTS_LEFT - WAIT_SLEEPS_USED))
  [ "$LONG_RUNNING_ATTEMPTS_LEFT" -lt 0 ] && LONG_RUNNING_ATTEMPTS_LEFT=0
  if [ "$long_rc" -eq "$SKIP_DEPLOY" ]; then
    exit 0
  elif [ "$long_rc" -ne 0 ]; then
    exit "$long_rc"
  fi
done

ECR_REGISTRY=${ECR_REGISTRY}
WEB_REPO=${ECR_REGISTRY}/gumroad/web
WEB_TAG=$(echo $BUILDKITE_COMMIT | cut -c1-12)
PRODUCTION_TAG="production-${WEB_TAG}"

logger "Deploying production image $WEB_REPO:$PRODUCTION_TAG"

# Ensure the production image exists
if ! docker manifest inspect $WEB_REPO:$PRODUCTION_TAG > /dev/null 2>&1; then
  logger "Error: Production image $WEB_REPO:$PRODUCTION_TAG does not exist"
  exit 1
fi

# Install Nomad
source .buildkite/scripts/install_nomad.sh
install_nomad

# Copy secrets from credentials repo
source .buildkite/scripts/copy_secrets.sh
copy_secrets

# Ensure necessary directories exist with proper permissions
logger "Creating required directories"
sudo mkdir -p nomad/production/certs
sudo mkdir -p nomad/certs
sudo chown -R buildkite-agent:buildkite-agent nomad/

gem install colorize
gem install dotenv

# Deploy to production
logger "Starting production deployment"
DEPLOYMENT_FROM_CI=true bin/deploy

logger "Successfully deployed $WEB_REPO:$PRODUCTION_TAG to production"

# Create GitHub Release with calendar versioning and auto-generated changelog
logger "Creating GitHub Release"
source .buildkite/scripts/create_github_release.sh
