#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_branch.sh: $1${NC}"
}

# The branch app nginx image is built and pushed by the parallel
# "Build Branch App Nginx Image" step (.buildkite/scripts/build_branch_app_nginx.sh),
# which this step depends on via the pipeline topology in .buildkite/preview.yml.
REVISION=${BUILDKITE_COMMIT}
WEB_TAG=$(echo $REVISION | cut -c1-12)

# Deploy preview app
logger "Starting preview app deployment"

# Install Nomad
source .buildkite/scripts/install_nomad.sh
install_nomad

# Copy secrets from credentials repo
source .buildkite/scripts/copy_secrets.sh
copy_secrets

# Surface the preview app on the PR via GitHub's Deployments API ("View deployment").
# Sourced here because deploy_branch_common.sh is provided by copy_secrets above.
source nomad/staging/deploy_branch/deploy_branch_common.sh
source .buildkite/scripts/github_deployment.sh

APP_NAME=$(get_app_name "$BUILDKITE_BRANCH")
PREVIEW_URL="https://${APP_NAME}.apps.staging.gumroad.org"
DEPLOYMENT_ID=$(create_github_deployment "$BUILDKITE_COMMIT" "preview/${APP_NAME}" || true)
set_github_deployment_status "$DEPLOYMENT_ID" "in_progress" || true
trap 'set_github_deployment_status "$DEPLOYMENT_ID" "failure" || true' ERR

BRANCH=${BUILDKITE_BRANCH}
DEPLOY_TAG="staging-${WEB_TAG}"

logger "Deploying preview app for ${BRANCH} with tag ${DEPLOY_TAG}"

# Ensure necessary directories exist with proper permissions
logger "Creating required directories"
sudo mkdir -p nomad/staging/certs
sudo mkdir -p nomad/certs
sudo chown -R buildkite-agent:buildkite-agent nomad/

# Deploy preview app
cd nomad/staging/deploy_branch
BRANCH=$BRANCH \
  DEPLOY_TAG=$DEPLOY_TAG \
  ./deploy.sh

set_github_deployment_status "$DEPLOYMENT_ID" "success" "$PREVIEW_URL" || true
logger "Preview app available at ${PREVIEW_URL}"
