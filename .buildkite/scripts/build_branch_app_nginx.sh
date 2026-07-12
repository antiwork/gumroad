#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_branch_app_nginx.sh: $1${NC}"
}

# Build the preview app nginx image. Its tag is content-addressed (last commit
# touching docker/branch_app_nginx), so it does not depend on compiled assets
# or the web image and can run in parallel with the rest of the pipeline.
AWS_BRANCH_APP_NGINX_REPO=${ECR_REGISTRY}/gumroad/branch_app_nginx

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
