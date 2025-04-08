#!/bin/bash
set -e

GREEN='\033[0;32m'
NC='\033[0m'
logger() {
  DT=$(date '+%Y/%m/%d %H:%M:%S')
  echo -e "${GREEN}$DT compile_assets.sh: $1${NC}"
}

quietly() {
  if [ "$TRIM_DOCKER_OUTPUT" = true ]; then
    touch /tmp/compile_assets-logs.txt
    "$@" 2>&1 >/tmp/compile_assets-logs.txt;
  else
    "$@"
  fi
}

ECR_REGISTRY=${ECR_REGISTRY}
WEB_REPO=${ECR_REGISTRY}/gumroad/web
REVISION=${BUILDKITE_COMMIT}
WEB_TAG=$(echo $REVISION | cut -c1-12)
COMPOSE_PROJECT_NAME=web_${BUILDKITE_BUILD_NUMBER}_compile_assets

pull_web_image() {
  logger "pulling $WEB_REPO:web-$WEB_TAG"
  for i in {1..3}; do
    logger "Attempt $i"
    if quietly docker pull $WEB_REPO:web-$WEB_TAG; then
      logger "Pulled $WEB_REPO:web-$WEB_TAG"
      return 0
    elif [ $i -eq 3 ]; then
      logger "Failed to pull $WEB_REPO:web-$WEB_TAG after 3 attempts"
      return 1
    fi
    sleep 5
  done
}

push_image() {
  local env=$1
  logger "Pushing $WEB_REPO:$env-$WEB_TAG"
  for i in {1..3}; do
    logger "Push attempt $i"
    if quietly docker push $WEB_REPO:$env-$WEB_TAG; then
      logger "Pushed $WEB_REPO:$env-$WEB_TAG"
      return 0
    elif [ $i -eq 3 ]; then
      logger "Failed to push $WEB_REPO:$env-$WEB_TAG after 3 attempts"
      return 1
    fi
    sleep 5
  done
}

logger "Restore web image if not already loaded"
if [[ ! $(docker images -q --filter "reference=$WEB_REPO:web-$WEB_TAG") ]]; then
  pull_web_image || exit 1
fi

if [[ $BUILDKITE_PARALLEL_JOB = 0 && $BUILDKITE_BRANCH != "main" ]]; then
  logger "Building staging assets"
  docker rm staging-assets || :
  COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}_staging \
    NEW_WEB_TAG=$WEB_TAG \
    NEW_WEB_REPO=$WEB_REPO \
    BUILDKITE_BRANCH=${BUILDKITE_BRANCH} \
    GUM_AWS_ACCESS_KEY_ID=${GUM_AWS_ACCESS_KEY_ID} \
    GUM_AWS_SECRET_ACCESS_KEY=${GUM_AWS_SECRET_ACCESS_KEY} \
    RAILS_STAGING_MASTER_KEY="$RAILS_STAGING_MASTER_KEY" \
    PUSH_ASSETS=true \
    make build_staging

  push_image staging || exit 1
fi

if [[ $BUILDKITE_PARALLEL_JOB = 1 && ! $BUILDKITE_BRANCH =~ ^deploy-.* ]]; then
  logger "Building production assets"
  docker rm production-assets || :
  COMPOSE_PROJECT_NAME=${COMPOSE_PROJECT_NAME}_production \
    NEW_WEB_TAG=$WEB_TAG \
    NEW_WEB_REPO=$WEB_REPO \
    BUILDKITE_BRANCH=${BUILDKITE_BRANCH} \
    GUM_AWS_ACCESS_KEY_ID=${GUM_AWS_ACCESS_KEY_ID} \
    GUM_AWS_SECRET_ACCESS_KEY=${GUM_AWS_SECRET_ACCESS_KEY} \
    RAILS_PRODUCTION_MASTER_KEY="$RAILS_PRODUCTION_MASTER_KEY" \
    PUSH_ASSETS=true \
    make build_production

  push_image production || exit 1
fi
