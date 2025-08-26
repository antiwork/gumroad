#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_web.sh: $1${NC}"
}

WEB_REPO=${ECR_REGISTRY}/gumroad/web
WEB_BASE_REPO=${ECR_REGISTRY}/gumroad/web_base
AWS_NGINX_REPO=${ECR_REGISTRY}/gumroad/web_nginx
REVISION=${BUILDKITE_COMMIT}

logger "pulling ruby:$(cat .ruby-version)-slim-bullseye"
docker pull --quiet ruby:$(cat .ruby-version)-slim-bullseye

WEB_BASE_SHA=$(docker/base/generate_tag_for_web_base.sh)
WEB_TAG=$(echo $REVISION | cut -c1-12)

# Copy secrets from credentials repo
source .buildkite/scripts/copy_secrets.sh
copy_secrets

# Build web image
logger "Building $WEB_REPO:web-$WEB_TAG"
NEW_WEB_TAG=$WEB_TAG \
  NEW_WEB_REPO=$WEB_REPO \
  NEW_BASE_REPO=$WEB_BASE_REPO \
  make build

# Push web image
logger "Pushing $WEB_REPO:web-$WEB_TAG"
for i in {1..3}; do
  logger "Push attempt $i"
  if docker push --quiet $WEB_REPO:web-$WEB_TAG; then
    logger "Pushed $WEB_REPO:web-$WEB_TAG"
    break
  elif [ $i -eq 3 ]; then
    logger "Failed to push $WEB_REPO:web-$WEB_TAG after 3 attempts"
    exit 1
  else
    sleep 5
  fi
done

function generate_nginx_tag() {
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

# Build and push nginx image
NGINX_TAG=$(generate_nginx_tag "public" "docker/nginx")
logger "Building $AWS_NGINX_REPO:$NGINX_TAG"
NGINX_TAG=$NGINX_TAG \
  NGINX_REPO=$AWS_NGINX_REPO \
  make build_nginx

logger "Pushing $AWS_NGINX_REPO:$NGINX_TAG"
for i in {1..3}; do
  logger "Push attempt $i"
  if docker push --quiet $AWS_NGINX_REPO:$NGINX_TAG; then
    logger "Pushed $AWS_NGINX_REPO:$NGINX_TAG"
    break
  elif [ $i -eq 3 ]; then
    logger "Failed to push $AWS_NGINX_REPO:$NGINX_TAG after 3 attempts"
    exit 1
  else
    sleep 5
  fi
done
