#!/bin/bash
set -e

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build.sh: $1${NC}"
}

WEB_BASE_REPO=${ECR_REGISTRY}/gumroad/web_base

logger "pulling ruby:$(cat .ruby-version)-slim-bullseye"
docker pull --quiet ruby:$(cat .ruby-version)-slim-bullseye
WEB_BASE_SHA=$(docker/base/generate_tag_for_web_base.sh)
if ! docker manifest inspect $WEB_BASE_REPO:$WEB_BASE_SHA > /dev/null 2>&1; then
  logger "Building $WEB_BASE_REPO:$WEB_BASE_SHA"
  NEW_BASE_REPO=$WEB_BASE_REPO \
    BUNDLE_GEMS__CONTRIBSYS__COM=$BUNDLE_GEMS__CONTRIBSYS__COM \
    make build_base

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
