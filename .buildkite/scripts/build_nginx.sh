#!/bin/bash
set -euo pipefail

# Keep tag calculation shared with the deploy scripts; a copied implementation
# can push an image the deploy never asks Nomad to run.
source "$(git rev-parse --show-toplevel)/ci_scripts/helper.sh"
source "$(git rev-parse --show-toplevel)/.buildkite/scripts/buildkit_cache.sh"

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_nginx.sh: $1${NC}"
}

AWS_NGINX_REPO=${ECR_REGISTRY}/gumroad/web_nginx
NGINX_TAG=$(generate_nginx_tag "public" "docker/nginx")

if ! docker manifest inspect "$AWS_NGINX_REPO:$NGINX_TAG" > /dev/null 2>&1; then
  build_image() {
    NGINX_REPO=$AWS_NGINX_REPO \
      NGINX_TAG=$NGINX_TAG \
      make build_nginx "$@"
  }

  logger "Building $AWS_NGINX_REPO:$NGINX_TAG"
  if buildkit_cache_available; then
    logger "Using BuildKit registry cache ($AWS_NGINX_REPO:buildcache)"
    if ! build_image \
      DOCKER_BUILD="$(buildkit_docker_build)" \
      NGINX_CACHE_OPTS="$(buildkit_cache_opts "$AWS_NGINX_REPO:buildcache")"; then
      buildkit_fallback_notice "web_nginx" "buildx build failed"
      build_image
    fi
  else
    buildkit_fallback_notice "web_nginx" "buildx unavailable"
    build_image
  fi

  logger "Pushing $AWS_NGINX_REPO:$NGINX_TAG"
  for i in {1..3}; do
    logger "Attempt $i"
    if docker push "$AWS_NGINX_REPO:$NGINX_TAG"; then
      logger "Pushed $AWS_NGINX_REPO:$NGINX_TAG"
      break
    elif [ $i -eq 3 ]; then
      logger "All push attempts failed"
      exit 1
    else
      sleep 5
    fi
  done
else
  logger "Image $AWS_NGINX_REPO:$NGINX_TAG already exists"
fi
