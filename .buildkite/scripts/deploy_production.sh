#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_production.sh: $1${NC}"
}

# Hold deploys only while a job that must not be interrupted is ACTUALLY running, by asking
# the app: payout batch jobs and the finance/tax report generators each register a Redis
# token while they run (see HoldsDeployWhileRunning), and /healthcheck/deploy_safe returns
# 503 while any of them is in flight. This is what replaced the blanket midnight-6am ET
# block in .github/workflows/tests.yml, which refused to auto-unblock deploys for six hours
# a night on the assumption that those jobs were running.
# Note this tracks jobs that are RUNNING, not work still scheduled to start, so a deploy can
# land in a gap between payout slices. That is safe: scheduled slices survive in Redis, and a
# recycled running slice is re-run by Sidekiq (re-running is idempotent — sellers whose
# payouts were already created are skipped).
# Poll for up to 45 minutes, then proceed with a warning rather than dropping the deploy
# silently. The Friday batch dispatches its slices over roughly the first half hour and the
# slices drain after that, so a 503 can persist for a while on Fridays.
# The endpoint is asked for twice, newest name first. /healthcheck/deploy_safe is the name
# this change introduces, and this script runs BEFORE the app that serves it is deployed —
# so on this change's own first deploy the still-running old app answers 404. In that case
# ask the old name, /healthcheck/payouts, which the old app does serve and which the new app
# keeps as an alias. Without that second ask the first deploy would get a 404, treat the
# healthcheck as broken, and fall through to the clock, losing the live check exactly once.
# Fallback: if NEITHER name answers 200 or 503, the healthcheck is genuinely unreachable —
# fall back to the clock: skip the deploy during the payout batch window (Tue-Fri UTC
# 10:00-10:59) and during the overnight cron window (UTC 04:00-09:59, i.e. midnight-6am ET,
# when the report jobs run) — so a broken healthcheck can never let a deploy land mid-run.
deploy_safe_healthcheck_url="https://gumroad.com/healthcheck/deploy_safe"
legacy_healthcheck_url="https://gumroad.com/healthcheck/payouts"
probe_deploy_safe() {
  local status
  status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$deploy_safe_healthcheck_url" || echo "000")
  if [ "$status" != "200" ] && [ "$status" != "503" ]; then
    status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$legacy_healthcheck_url" || echo "000")
  fi
  echo "$status"
}
for attempt in $(seq 1 15); do
  hc_status=$(probe_deploy_safe)
  if [ "$hc_status" = "200" ]; then
    break
  elif [ "$hc_status" = "503" ]; then
    logger "Long-running job in flight (healthcheck 503) — waiting 3 minutes (attempt $attempt/15)"
    sleep 180
  else
    current_utc_hour=$(date -u +%H)
    current_utc_dow=$(date -u +%u) # 1=Mon .. 7=Sun
    if [ "$current_utc_dow" -ge 2 ] && [ "$current_utc_dow" -le 5 ] && [ "$current_utc_hour" -eq 10 ]; then
      logger "Deploy-safety healthcheck unreachable (neither path answered; last HTTP $hc_status) during the payout batch window (Tue-Fri UTC 10:00-11:00) — skipping deployment"
      exit 0
    fi
    if [ "$current_utc_hour" -ge 4 ] && [ "$current_utc_hour" -lt 10 ]; then
      logger "Deploy-safety healthcheck unreachable (neither path answered; last HTTP $hc_status) during the overnight cron window (UTC 04:00-10:00 / midnight-6am ET) — skipping deployment"
      exit 0
    fi
    logger "Deploy-safety healthcheck unreachable (neither path answered; last HTTP $hc_status) outside the fallback windows — proceeding"
    break
  fi
  if [ "$attempt" = "15" ]; then
    logger "WARNING: a long-running job is still in flight after 45 minutes — proceeding with deploy anyway (these jobs retry after a worker recycle; this warning means the run is unusually slow and worth a look)"
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
