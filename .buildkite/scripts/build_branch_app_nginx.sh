#!/bin/bash
set -euo pipefail

# The nginx tag function lives in ci_scripts/helper.sh so this build step and
# the nomad deploy scripts always compute the same tag from the same commit —
# a drifted copy here would push an image the deploy never looks for.
# (Sourced first: helper.sh also defines a generic logger; ours below wins.)
source "$(git rev-parse --show-toplevel)/ci_scripts/helper.sh"
source "$(git rev-parse --show-toplevel)/.buildkite/scripts/buildkit_cache.sh"

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_branch_app_nginx.sh: $1${NC}"
}

# Build the preview app nginx image. Its tag is content-addressed (last commit
# touching docker/branch_app_nginx), so it does not depend on compiled assets
# or the web image and can run in parallel with the rest of the pipeline.
AWS_BRANCH_APP_NGINX_REPO=${ECR_REGISTRY}/gumroad/branch_app_nginx

BRANCH_APP_NGINX_TAG=$(generate_nginx_tag "docker/branch_app_nginx")

if ! docker manifest inspect "$AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG" > /dev/null 2>&1; then
  build_image() {
    BRANCH_APP_NGINX_REPO=$AWS_BRANCH_APP_NGINX_REPO \
      BRANCH_APP_NGINX_TAG=$BRANCH_APP_NGINX_TAG \
      make build_branch_app_nginx "$@"
  }

  logger "Building $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"
  if buildkit_cache_available; then
    logger "Using BuildKit registry cache ($AWS_BRANCH_APP_NGINX_REPO:buildcache)"
    if ! build_image \
      DOCKER_BUILD="$(buildkit_docker_build)" \
      BRANCH_APP_NGINX_CACHE_OPTS="$(buildkit_cache_opts "$AWS_BRANCH_APP_NGINX_REPO:buildcache")"; then
      buildkit_fallback_notice "branch_app_nginx" "buildx build failed"
      build_image
    fi
  else
    buildkit_fallback_notice "branch_app_nginx" "buildx unavailable"
    build_image
  fi

  logger "Pushing $AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"
  for i in {1..3}; do
    logger "Attempt $i"
    if docker push "$AWS_BRANCH_APP_NGINX_REPO:$BRANCH_APP_NGINX_TAG"; then
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
