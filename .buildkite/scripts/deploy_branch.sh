#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") deploy_branch.sh: $1${NC}"
}

# Build preview app nginx image
AWS_BRANCH_APP_NGINX_REPO=${ECR_REGISTRY}/gumroad/branch_app_nginx
REVISION=${BUILDKITE_COMMIT}

function generate_nginx_tag(){
  local paths=()
  local app_dir
  app_dir=$(git rev-parse --show-toplevel)

  # Change relative paths to absolute paths
  for arg in "$@"; do
    paths+=("${app_dir}/${arg}")
  done

  # Get short SHA of the latest commit affecting the paths
  git rev-list --abbrev-commit --abbrev=12 HEAD -1 -- "${paths[@]}"
}

BRANCH_APP_NGINX_TAG=$(generate_nginx_tag "docker/branch_app_nginx")

logger "Checking if web image exists"
WEB_TAG=$(echo $REVISION | cut -c1-12)
WEB_REPO=${ECR_REGISTRY}/gumroad/web

if ! docker manifest inspect $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG > /dev/null 2>&1; then
  logger "Building $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"
  BRANCH_APP_NGINX_REPO=$AWS_BRANCH_APP_NGINX_REPO \
    BRANCH_APP_NGINX_TAG=$BRANCH_APP_NGINX_TAG \
    make build_branch_app_nginx

  logger "Pushing $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"
  for i in {1..3}; do
    logger "Attempt $i"
    if docker push $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG; then
      logger "Pushed $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"
      break
    elif [ $i -eq 3 ]; then
      logger "All push attempts failed"
      exit 1
    else
      sleep 5
    fi
  done
else
  logger "Image $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG already exists"
fi

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
