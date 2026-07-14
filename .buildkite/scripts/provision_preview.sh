#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") provision_preview.sh: $1${NC}"
}

# Runs the asset-independent half of a preview deploy — spin up the EC2
# instance, create the app's databases/redis, and run first-deploy migrations —
# in parallel with the "Compile Assets" step (both depend only on the web
# image). The app boot itself, which needs the compiled assets, happens later in
# the "Deploy Preview App" step (deploy_branch.sh, which runs the "release"
# phase). See nomad/staging/deploy_branch/deploy.sh for the phase split.
#
# On a redeploy the environment already exists, so the provision phase is a
# no-op; this step then just confirms nothing is needed and exits quickly.

REVISION=${BUILDKITE_COMMIT}
WEB_TAG=$(echo $REVISION | cut -c1-12)

logger "Starting preview app provisioning"

# Install Nomad
source .buildkite/scripts/install_nomad.sh
install_nomad

# Copy secrets from credentials repo (also brings in the nomad/ deploy tree)
source .buildkite/scripts/copy_secrets.sh
copy_secrets

BRANCH=${BUILDKITE_BRANCH}
DEPLOY_TAG="staging-${WEB_TAG}"

logger "Provisioning preview environment for ${BRANCH} with tag ${DEPLOY_TAG}"

# Ensure necessary directories exist with proper permissions (mirrors
# deploy_branch.sh; the nomad jobs write rendered specs and certs under nomad/).
logger "Creating required directories"
sudo mkdir -p nomad/staging/certs
sudo mkdir -p nomad/certs
sudo chown -R buildkite-agent:buildkite-agent nomad/

cd nomad/staging/deploy_branch
BRANCH=$BRANCH \
  DEPLOY_TAG=$DEPLOY_TAG \
  ./deploy.sh provision

logger "Preview environment provisioned for ${BRANCH}"
