#!/bin/bash

# Builds and pushes the image for one Go service directory (resend_callbacks, go_web) to
# gumroad/<dir>. The tag is the last commit touching <dir>/, the same tag the deployer computes
# (nomad/common.sh), so a commit that leaves the directory alone reuses the pushed image.

set -e

SERVICE_DIR=$1
if [ -z "$SERVICE_DIR" ] || [ ! -d "$SERVICE_DIR" ]; then
  echo "usage: build_go_image.sh <service directory>" >&2
  exit 1
fi

# Sourced first: helper.sh also defines a generic logger; ours below wins.
source ci_scripts/helper.sh
source .buildkite/scripts/deploy_relevance.sh

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") build_go_image.sh ${SERVICE_DIR}: $1${NC}"
}

skip_if_production_noop "build_go_image.sh ${SERVICE_DIR}"

REPO=${ECR_REGISTRY}/gumroad/${SERVICE_DIR}
TAG=$(generate_nginx_tag "$SERVICE_DIR")
if [ -z "$TAG" ]; then
  logger "No commit touches ${SERVICE_DIR}/, so there is nothing to tag"
  exit 1
fi

if docker manifest inspect "$REPO:$TAG" > /dev/null 2>&1; then
  logger "$REPO:$TAG already exists"
  exit 0
fi

logger "Building $REPO:$TAG"
docker build --pull -t "$REPO:$TAG" "$SERVICE_DIR"

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
