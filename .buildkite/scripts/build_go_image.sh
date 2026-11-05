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

# go_web bakes in the GeoIP database and the encrypted Rails credentials (decrypted with
# RAILS_MASTER_KEY) that copy_secrets.sh put on the agent. Their digests join the tag so a
# refreshed file ships without a go_web/ commit.
if [ "$SERVICE_DIR" = "go_web" ]; then
  if [ -s lib/GeoIP2-City.mmdb ]; then
    cp lib/GeoIP2-City.mmdb go_web/GeoIP2-City.mmdb
    TAG="${TAG}-geoip-$(sha256sum go_web/GeoIP2-City.mmdb | cut -c1-12)"
  fi
  if [ -s config/credentials/production.yml.enc ]; then
    mkdir -p go_web/credentials
    cp config/credentials/production.yml.enc go_web/credentials/production.yml.enc
    TAG="${TAG}-creds-$(sha256sum go_web/credentials/production.yml.enc | cut -c1-12)"
  fi
  # The Vite manifests of the web image this build deploys, so go_web's pages load the
  # assets Rails' do. compile_assets.sh left that image here; without it go_web's pages go
  # to Rails. The whole .vite directory, so go_web loads exactly the manifests Rails does.
  WEB_IMAGE="${ECR_REGISTRY}/gumroad/web:production-$(echo "$BUILDKITE_COMMIT" | cut -c1-12)"
  rm -rf go_web/vite
  if ! docker image inspect "$WEB_IMAGE" > /dev/null 2>&1; then
    logger "No $WEB_IMAGE on this agent, so go_web has no Vite manifests"
  elif ! CONTAINER=$(docker create "$WEB_IMAGE"); then
    logger "Could not create a container from $WEB_IMAGE, so go_web has no Vite manifests"
  else
    if docker cp "$CONTAINER:/app/public/vite/.vite" go_web/vite && [ -s go_web/vite/manifest.json ]; then
      TAG="${TAG}-vite-$(cat go_web/vite/*.json | sha256sum | cut -c1-12)"
    else
      rm -rf go_web/vite
      logger "Could not copy the Vite manifests out of $WEB_IMAGE, so go_web has none"
    fi
    docker rm "$CONTAINER" > /dev/null || true
  fi
fi
# The deploy step reads the tag from here rather than recomputing the digest.
if command -v buildkite-agent >/dev/null 2>&1; then
  buildkite-agent meta-data set "go-image-tag-${SERVICE_DIR}" "$TAG"
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
