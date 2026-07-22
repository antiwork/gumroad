#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_production.sh: $1${NC}"
}

# Skip deploys only while a weekly payout batch may be running.
# Batches are enqueued at UTC 10:00 on Tue-Fri (cross-border/non-US/US/PayPal+Connect)
# and complete in 10-30 minutes (measured from payments.created_at bursts, July 2026;
# worst observed: ~30 min on the US batch). One hour gives 2x headroom.
# Sat/Sun/Mon have no weekly batch, so deploys are never blocked on those days.
current_utc_hour=$(date -u +%H)
current_utc_dow=$(date -u +%u) # 1=Mon .. 7=Sun
if [ "$current_utc_dow" -ge 2 ] && [ "$current_utc_dow" -le 5 ] && [ "$current_utc_hour" -eq 10 ]; then
  logger "Skipping deployment to production during weekly payout batch (Tue-Fri UTC 10:00 to 11:00)"
  exit 0
fi

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
