#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_production.sh: $1${NC}"
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
wait_for_healthcheck() {
  local label="$1" url="$2" max_attempts="$3" on_timeout="$4" failsafe_window_test="$5"
  local attempt hc_status

  for attempt in $(seq 1 "$max_attempts"); do
    # On a connection failure curl already writes "000" to stdout, so the `|| echo` fallback
    # is only for the case where curl writes nothing at all. Either way the value is not
    # 200/503 and falls through to the unreachable branch below.
    hc_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url") || hc_status="000"
    if [ "$hc_status" = "200" ]; then
      return 0
    elif [ "$hc_status" = "503" ]; then
      logger "$label in flight (healthcheck 503) — waiting 3 minutes (attempt $attempt/$max_attempts)"
      sleep 180
    elif [ "$hc_status" = "404" ]; then
      if eval "$failsafe_window_test"; then
        logger "$label healthcheck absent (HTTP 404) inside the fail-safe window — skipping deployment"
        exit 0
      fi
      logger "$label healthcheck absent (HTTP 404) outside the fail-safe window — proceeding"
      return 0
    else
      if eval "$failsafe_window_test"; then
        logger "$label healthcheck unreachable (HTTP $hc_status) inside the fail-safe window — skipping deployment"
        exit 0
      fi
      logger "$label healthcheck unreachable (HTTP $hc_status) outside the fail-safe window — proceeding"
      return 0
    fi
  done

  if [ "$on_timeout" = "skip" ]; then
    logger "$label still in flight after $((max_attempts * 3)) minutes — skipping deployment (the change ships with the next push, or click require-approval to force it)"
    exit 0
  fi
  logger "WARNING: $label still in flight after $((max_attempts * 3)) minutes — proceeding with deploy anyway (this means it is unusually slow and worth a look)"
  return 0
}

# Payout batches. Tracking is per RUNNING job, not per batch, so a deploy can land in a gap
# between slices. That is safe: scheduled slices sit in Redis and survive a deploy, and a
# slice killed mid-run is re-run by Sidekiq (sellers already paid are skipped). Because of
# that, proceeding after the wait is acceptable — worst case a slice gets re-run. The Friday
# batch dispatches its slices over roughly half an hour, so 45 minutes of patience.
# Fail-safe window: Tue-Fri UTC 10:00-10:59, when the weekly batches are enqueued.
wait_for_healthcheck "Payout batch" "https://gumroad.com/healthcheck/payouts" 15 proceed \
  '[ "$(date -u +%u)" -ge 2 ] && [ "$(date -u +%u)" -le 5 ] && [ "$(date -u +%H)" -eq 10 ]'

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
wait_for_healthcheck "Long-running job" "https://gumroad.com/healthcheck/long_running_jobs" 40 skip \
  '[ "$(date -u +%-H)" -le 5 ] || { [ "$(date -u +%-H)" -ge 8 ] && [ "$(date -u +%-H)" -le 13 ]; }'

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
