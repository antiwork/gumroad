#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_web.sh: $1${NC}"
}

source .buildkite/scripts/buildkit_cache.sh

WEB_REPO=${ECR_REGISTRY}/gumroad/web
WEB_BASE_REPO=${ECR_REGISTRY}/gumroad/web_base
REVISION=${BUILDKITE_COMMIT}
RUBY_IMAGE=ruby:$(cat .ruby-version)-slim-bullseye

# The Makefile's generate_tag_for_web_base.sh hashes `docker history` of the
# ruby base image, so it must be present and current locally. The helper always
# pulls (cheap manifest check when already current) and only falls back to an
# existing local copy if the pull fails, e.g. during a Docker Hub outage.
pull_ruby_base_image "$RUBY_IMAGE"

WEB_TAG=$(echo $REVISION | cut -c1-12)

# Copy secrets from credentials repo
source .buildkite/scripts/copy_secrets.sh
copy_secrets

# Build web image
build_web_image() {
  NEW_WEB_TAG=$WEB_TAG \
    NEW_WEB_REPO=$WEB_REPO \
    NEW_BASE_REPO=$WEB_BASE_REPO \
    make build "$@"
}

logger "Building $WEB_REPO:web-$WEB_TAG"
WEB_IMAGE_PUSHED=false
if buildkit_cache_available; then
  logger "Using BuildKit registry cache ($WEB_REPO:buildcache); pushing web-$WEB_TAG straight from the builder"
  if build_web_image \
    DOCKER_BUILD="$(buildkit_docker_build_push)" \
    WEB_OUTPUT_OPTS="-t $WEB_REPO:web-$WEB_TAG" \
    WEB_POST_BUILD=":" \
    WEB_CACHE_OPTS="$(buildkit_cache_opts $WEB_REPO:buildcache)"; then
    # --push already uploaded web-$WEB_TAG to ECR as part of the build, so the
    # separate push loop below would be a redundant (if cheap) re-upload.
    WEB_IMAGE_PUSHED=true
  else
    buildkit_fallback_notice "web" "buildx build failed"
    build_web_image
  fi
else
  buildkit_fallback_notice "web" "buildx unavailable"
  build_web_image
fi

# Push web image (already done by the builder on the BuildKit path above)
if [ "$WEB_IMAGE_PUSHED" = "true" ]; then
  logger "$WEB_REPO:web-$WEB_TAG already pushed by the builder"
else
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
fi
