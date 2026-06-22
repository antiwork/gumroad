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

# Compiled frontend output produced by `assets:precompile` (no sprockets):
# the vite build + manifest, widget bundles, and the pages Tailwind stylesheet.
ASSET_OUTPUT_PATHS="public/vite public/js public/pages-tailwind.css"

# Sanitized branch name, safe to use as part of an image tag.
branch_slug() {
  echo "$BUILDKITE_BRANCH" | tr -c '[:alnum:]' '-' | tr '[:upper:]' '[:lower:]' | cut -c1-100 | sed 's/-*$//'
}

# Most recent commit touching anything that affects the compiled assets. Stable
# across commits that leave the frontend untouched, so the cache can be reused.
asset_content_tag() {
  git rev-list --abbrev-commit --abbrev=12 -1 HEAD -- \
    app/javascript package.json package-lock.json \
    vite.config.ts vite.config.widget.ts config/vite.json \
    scripts/build_pages_tailwind.mjs tsconfig.json 2>/dev/null
}

# Store the freshly compiled assets for <target> env as a slim cache image.
save_asset_cache() {
  local target=$1 cache_image=$2 tmp cid path ok=1
  tmp=$(mktemp -d) || return 1
  cid=$(docker create "$WEB_REPO:$target-$WEB_TAG") || { rm -rf "$tmp"; return 1; }
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
# <target> image, skipping the (~7 min) vite build.
overlay_assets() {
  local target=$1 cache_image=$2 tmp ccid wcid ok=1
  docker pull "$cache_image" >/dev/null 2>&1 || return 1
  tmp=$(mktemp -d) || return 1
  ccid=$(docker create "$cache_image") || { rm -rf "$tmp"; return 1; }
  if docker cp "$ccid:/cache/public" "$tmp/public" 2>/dev/null; then
    wcid=$(docker create "$WEB_REPO:web-$WEB_TAG") || wcid=""
    if [[ -n "$wcid" ]] && docker cp "$tmp/public/." "$wcid:/app/public/" 2>/dev/null \
      && docker commit "$wcid" "$WEB_REPO:$target-$WEB_TAG" >/dev/null 2>&1; then
      ok=0
    fi
    [[ -n "$wcid" ]] && docker rm "$wcid" >/dev/null 2>&1 || true
  fi
  docker rm "$ccid" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  return $ok
}

# Reuse cached compiled assets when the frontend is unchanged, otherwise compile.
# Keyed per branch because the bundle can bake in branch-specific values
# (e.g. CUSTOM_DOMAIN on preview apps); each env keeps its own cache.
compile_assets_for_env() {
  local target=$1 master_key=$2
  local asset_key cache_image compiled_from_cache=false
  local master_key_var="RAILS_$(printf '%s' "$target" | tr '[:lower:]' '[:upper:]')_MASTER_KEY"
  asset_key=$(asset_content_tag || true)
  cache_image="$WEB_REPO:${target}-assets-${asset_key}-$(branch_slug)"

  if [[ -n "$asset_key" ]] && docker manifest inspect "$cache_image" > /dev/null 2>&1; then
    logger "Asset cache hit ($cache_image); overlaying onto web-$WEB_TAG and skipping the vite build"
    if overlay_assets "$target" "$cache_image"; then
      compiled_from_cache=true
    else
      logger "Asset overlay failed; falling back to a full compile"
    fi
  else
    logger "Asset cache miss ($cache_image)"
  fi

  if [[ "$compiled_from_cache" != true ]]; then
    logger "Building $target assets"
    docker rm "$target-assets" || :
    env \
      COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME}_${target}" \
      NEW_WEB_TAG="$WEB_TAG" \
      NEW_WEB_REPO="$WEB_REPO" \
      BUILDKITE_BRANCH="$BUILDKITE_BRANCH" \
      GUM_AWS_ACCESS_KEY_ID="$GUM_AWS_ACCESS_KEY_ID" \
      GUM_AWS_SECRET_ACCESS_KEY="$GUM_AWS_SECRET_ACCESS_KEY" \
      "$master_key_var=$master_key" \
      PUSH_ASSETS=true \
      make "build_$target"

    if [[ -n "$asset_key" ]]; then
      save_asset_cache "$target" "$cache_image" \
        && logger "Saved asset cache ($cache_image)" \
        || logger "Saving asset cache failed; continuing"
    fi
  fi

  push_image "$target" || exit 1
}

logger "Restore web image if not already loaded"
if [[ ! $(docker images -q --filter "reference=$WEB_REPO:web-$WEB_TAG") ]]; then
  pull_web_image || exit 1
fi

if [[ $BUILDKITE_PARALLEL_JOB = 0 && $BUILDKITE_BRANCH != "main" ]]; then
  compile_assets_for_env staging "$RAILS_STAGING_MASTER_KEY"
fi

if [[ $BUILDKITE_PARALLEL_JOB = 1 && ( $BUILDKITE_BRANCH == "main" || $BUILDKITE_BRANCH == comp-assets-* ) ]]; then
  compile_assets_for_env production "$RAILS_PRODUCTION_MASTER_KEY"
fi
