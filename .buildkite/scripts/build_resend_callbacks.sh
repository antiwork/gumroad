#!/bin/bash

# Builds the Go receiver that runs on the Resend callback fleet. The image is tagged by the
# last commit touching resend_callbacks/, the same tag the deployer computes for the callback
# jobs (nomad/common.sh), so a commit that leaves the directory alone reuses the pushed image.

set -e

# Sourced first: helper.sh also defines a generic logger; ours below wins.
source ci_scripts/helper.sh
source .buildkite/scripts/deploy_relevance.sh

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_resend_callbacks.sh: $1${NC}"
}

skip_if_production_noop "build_resend_callbacks.sh"

REPO=${ECR_REGISTRY}/gumroad/resend_callbacks
TAG=$(generate_nginx_tag "resend_callbacks")
if [ -z "$TAG" ]; then
  logger "No commit touches resend_callbacks/, so there is nothing to tag"
  exit 1
fi

if docker manifest inspect "$REPO:$TAG" > /dev/null 2>&1; then
  logger "$REPO:$TAG already exists"
  exit 0
fi

logger "Building $REPO:$TAG"
docker build --pull -t "$REPO:$TAG" resend_callbacks

logger "Pushing $REPO:$TAG"
for i in {1..3}; do
  logger "Push attempt $i"
  if docker push --quiet "$REPO:$TAG"; then
    logger "Pushed $REPO:$TAG"
    break
  elif [ $i -eq 3 ]; then
    logger "Failed to push $REPO:$TAG after 3 attempts"
    exit 1
  else
    sleep 5
  fi
done
