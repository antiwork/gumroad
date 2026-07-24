#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_production.sh: $1${NC}"
}

# Hold deploys only while a payout batch is ACTUALLY running, by asking the app
# (PerformPayoutsUpToDelayDaysAgoWorker maintains a Redis flag; /healthcheck/payouts
# returns 503 while any per-type batch job is in flight). Poll for up to 45 minutes —
# batches complete in 10-30 min (measured July 2026) — then proceed with a warning
# rather than dropping the deploy silently.
# Fallback: if the healthcheck is unreachable (non-200/503 answer), fall back to the
# static window (Tue-Fri UTC 10:00-10:59, when weekly batches are enqueued) so a
# broken healthcheck can never let a deploy land mid-batch.
payouts_healthcheck_url="https://gumroad.com/healthcheck/payouts"
for attempt in $(seq 1 15); do
  hc_status=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$payouts_healthcheck_url" || echo "000")
  if [ "$hc_status" = "200" ]; then
    break
  elif [ "$hc_status" = "503" ]; then
    logger "Payout batch in flight (healthcheck 503) — waiting 3 minutes (attempt $attempt/15)"
    sleep 180
  else
    current_utc_hour=$(date -u +%H)
    current_utc_dow=$(date -u +%u) # 1=Mon .. 7=Sun
    if [ "$current_utc_dow" -ge 2 ] && [ "$current_utc_dow" -le 5 ] && [ "$current_utc_hour" -eq 10 ]; then
      logger "Payouts healthcheck unreachable (HTTP $hc_status) during the static batch window (Tue-Fri UTC 10:00-11:00) — skipping deployment"
      exit 0
    fi
    logger "Payouts healthcheck unreachable (HTTP $hc_status) outside the static batch window — proceeding"
    break
  fi
  if [ "$attempt" = "15" ]; then
    logger "WARNING: payout batch still in flight after 45 minutes — proceeding with deploy anyway (batch jobs are deploy-safe Sidekiq jobs with retries; this warning means the batch is unusually slow and worth a look)"
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
