#!/bin/bash
set -eo pipefail

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

# Compiled frontend output produced by the staging precompile (no sprockets):
# vite build + manifest, widget bundles, and the pages Tailwind stylesheet.
ASSET_OUTPUT_PATHS="public/vite public/js public/pages-tailwind.css"

get_app_name() {
  echo "$1" | tr -d '\n' | tr -c '[:alnum:]' '-' | tr '[:upper:]' '[:lower:]' | sed "s/^deploy-//" | cut -c1-32 | sed 's/[^[:alnum:]]$//'
}

# Most recent commit touching anything that affects the compiled assets. Stable
# across commits that leave the frontend untouched, so the cache can be reused.
asset_content_tag() {
  git rev-list --abbrev-commit --abbrev=12 -1 HEAD -- \
    app/javascript package.json package-lock.json \
    vite.config.ts vite.config.widget.ts config/vite.json \
    scripts/build_pages_tailwind.mjs tsconfig.json 2>/dev/null
}

# Store the freshly compiled assets as a slim cache image for next time.
save_staging_asset_cache() {
  local cache_image=$1 tmp cid path ok=1
  tmp=$(mktemp -d) || return 1
  cid=$(docker create "$WEB_REPO:staging-$WEB_TAG") || { rm -rf "$tmp"; return 1; }
  mkdir -p "$tmp/cache/public"
  for path in $ASSET_OUTPUT_PATHS; do
    docker cp "$cid:/app/$path" "$tmp/cache/$path" 2>/dev/null || true
  done
  docker rm "$cid" >/dev/null 2>&1 || true
  printf 'FROM busybox\nCOPY cache /cache\n' > "$tmp/Dockerfile"
  if docker build -t "$cache_image" "$tmp" >/dev/null 2>&1; then
    quietly docker push "$cache_image" && ok=0
  fi
  rm -rf "$tmp"
  return $ok
}

# Overlay cached compiled assets onto the current code image and commit it as the
# staging image, skipping the (~7 min) vite build. CUSTOM_DOMAIN is baked into the
# bundle, so the cache is keyed per branch and reuse here is for the same branch.
overlay_staging_assets() {
  local cache_image=$1 tmp ccid wcid ok=1
  docker pull "$cache_image" >/dev/null 2>&1 || return 1
  tmp=$(mktemp -d) || return 1
  ccid=$(docker create "$cache_image") || { rm -rf "$tmp"; return 1; }
  if docker cp "$ccid:/cache/public" "$tmp/public" 2>/dev/null; then
    wcid=$(docker create "$WEB_REPO:web-$WEB_TAG") || wcid=""
    if [[ -n "$wcid" ]] && docker cp "$tmp/public/." "$wcid:/app/public/" 2>/dev/null \
      && docker commit "$wcid" "$WEB_REPO:staging-$WEB_TAG" >/dev/null 2>&1; then
      ok=0
    fi
    [[ -n "$wcid" ]] && docker rm "$wcid" >/dev/null 2>&1 || true
  fi
  docker rm "$ccid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  return $ok
}

logger "Restore web image if not already loaded"
if [[ ! $(docker images -q --filter "reference=$WEB_REPO:web-$WEB_TAG") ]]; then
  pull_web_image || exit 1
fi

if [[ $BUILDKITE_PARALLEL_JOB = 0 && $BUILDKITE_BRANCH != "main" ]]; then
  app_name=$(get_app_name "$BUILDKITE_BRANCH")
  asset_key=$(asset_content_tag || true)
  asset_cache_image="$WEB_REPO:staging-assets-${asset_key}-${app_name}"
  compiled_from_cache=false

  if [[ -n "$asset_key" ]] && docker manifest inspect "$asset_cache_image" > /dev/null 2>&1; then
    logger "Asset cache hit ($asset_cache_image); overlaying onto web-$WEB_TAG and skipping the vite build"
    if overlay_staging_assets "$asset_cache_image"; then
      compiled_from_cache=true
    else
      logger "Asset overlay failed; falling back to a full compile"
    fi
  else
    logger "Asset cache miss ($asset_cache_image)"
  fi

  if [[ "$compiled_from_cache" != true ]]; then
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

    if [[ -n "$asset_key" ]]; then
      save_staging_asset_cache "$asset_cache_image" \
        && logger "Saved asset cache ($asset_cache_image)" \
        || logger "Saving asset cache failed; continuing"
    fi
  fi

  push_image staging || exit 1
fi

if [[ $BUILDKITE_PARALLEL_JOB = 1 && ( $BUILDKITE_BRANCH == "main" || $BUILDKITE_BRANCH == comp-assets-* ) ]]; then
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
