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
    hc_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url" || echo "000")
    if [ "$hc_status" = "200" ]; then
      return 0
    elif [ "$hc_status" = "503" ]; then
      logger "$label in flight (healthcheck 503) — waiting 3 minutes (attempt $attempt/$max_attempts)"
      sleep 180
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

# Long-running non-payout jobs — the monthly/quarterly finance and tax reports, sitemap
# rebuilds (see LongRunningJobTracking). These are NOT safe to interrupt: they hold no
# checkpoint, so a recycled worker means the run starts over, and killed runs of these are
# how finance reports have silently gone missing. So we wait longer (up to 2 hours, the
# slowest of them is the Canada sales report at well over an hour) and, if one is still
# running at the end of that, skip this deploy rather than kill the report.
# Fail-safe window: midnight-6am ET, when these jobs are scheduled. This check is what
# replaced blocking every deploy in that window outright.
wait_for_healthcheck "Long-running job" "https://gumroad.com/healthcheck/long_running_jobs" 40 skip \
  '[ "$(TZ=America/New_York date +%-H)" -lt 6 ]'

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
