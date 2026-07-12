#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build.sh: $1${NC}"
}

source .buildkite/scripts/buildkit_cache.sh

WEB_BASE_REPO=${ECR_REGISTRY}/gumroad/web_base
RUBY_IMAGE=ruby:$(cat .ruby-version)-slim-bullseye

# generate_tag_for_web_base.sh hashes `docker history` of the ruby base image,
# so it must be present and current locally. The helper always pulls (cheap
# manifest check when already current) and only falls back to an existing local
# copy if the pull fails, e.g. during a Docker Hub outage.
pull_ruby_base_image "$RUBY_IMAGE"

WEB_BASE_SHA=$(docker/base/generate_tag_for_web_base.sh)
if ! docker manifest inspect $WEB_BASE_REPO:$WEB_BASE_SHA > /dev/null 2>&1; then
  build_base_image() {
    NEW_BASE_REPO=$WEB_BASE_REPO \
      BUNDLE_GEMS__CONTRIBSYS__COM=$BUNDLE_GEMS__CONTRIBSYS__COM \
      make build_base "$@"
  }

  logger "Building $WEB_BASE_REPO:$WEB_BASE_SHA"
  if buildkit_cache_available; then
    logger "Using BuildKit registry cache ($WEB_BASE_REPO:buildcache)"
    if ! build_base_image \
      DOCKER_BUILD="$(buildkit_docker_build)" \
      BASE_CACHE_OPTS="$(buildkit_cache_opts $WEB_BASE_REPO:buildcache)"; then
      buildkit_fallback_notice "web_base" "buildx build failed"
      build_base_image
    fi
  else
    buildkit_fallback_notice "web_base" "buildx unavailable"
    build_base_image
  fi

  logger "Pushing $WEB_BASE_REPO:$WEB_BASE_SHA"
  for i in {1..3}; do
    logger "Push attempt $i"
    if docker push --quiet $WEB_BASE_REPO:$WEB_BASE_SHA; then
      logger "Pushed $WEB_BASE_REPO:$WEB_BASE_SHA"
      break
    elif [ $i -eq 3 ]; then
      logger "Failed to push $WEB_BASE_REPO:$WEB_BASE_SHA"
      exit 1
    else
      sleep 5
    fi
  done
else
  logger "$WEB_BASE_REPO:$WEB_BASE_SHA already exists"
fi
