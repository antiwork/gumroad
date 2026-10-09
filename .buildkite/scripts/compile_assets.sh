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

source .buildkite/scripts/preview_asset_cache.sh
source .buildkite/scripts/main_asset_cache.sh

# Skip the whole production pipeline when this commit changes nothing that ships
# (specs, workflows, docs, the pipeline itself). See deploy_relevance.sh.
source .buildkite/scripts/deploy_relevance.sh
skip_if_production_noop "compile_assets.sh"

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

# BUILDKITE_PARALLEL_JOB is unset when the step has no parallelism configured
# (preview.yml runs a single asset job); default to 0 so the staging build runs.
if [[ ${BUILDKITE_PARALLEL_JOB:-0} = 0 && $BUILDKITE_BRANCH != "main" ]]; then
  # Preview branches first check the content-addressed asset cache. On a hit
  # we skip the entire compile (npm install, js:export, Vite) and build the
  # staging image by extracting the previously compiled artifacts into a
  # fresh web-image container — same shape as the docker-commit the full
  # build produces, minutes instead of ~13.
  ASSET_CACHE_HIT=false
  if preview_asset_cache_enabled; then
    ASSET_CACHE_TAG=$(preview_asset_cache_tag)
    logger "Preview asset cache tag: $ASSET_CACHE_TAG"
    if preview_asset_cache_restore "$ASSET_CACHE_TAG"; then
      ASSET_CACHE_HIT=true
      logger "Preview asset cache HIT — skipping asset compile"
    else
      logger "Preview asset cache miss — running full asset compile"
    fi
  fi

  # Builds the staging image from the restored cache tarball. Mirrors what
  # `make build_staging` commits: spec/ removed, container labeled
  # assets_compiled=true, and the SAME -e env as the full build. That last
  # part matters: docker commit bakes the container's env into the image as
  # defaults, so a cache-hit image must carry exactly what a full-build image
  # carries. The tarball is mounted read-only; docker commit ignores mounted
  # paths, so only the extracted files end up in the image.
  build_staging_image_from_cache() {
    docker rm -f staging-assets-from-cache 2>/dev/null || :
    docker run \
      --name staging-assets-from-cache \
      --entrypoint="" \
      -e RAILS_ENV="staging" \
      -e RACK_ENV="staging" \
      -e DATABASE_HOST="db_test" \
      -e DATABASE_NAME="gumroad_test" \
      -e DATABASE_USERNAME="root" \
      -e DATABASE_PASSWORD="password" \
      -e DEVISE_SECRET_KEY="sample_secret_key" \
      -e RAILS_MASTER_KEY=$RAILS_STAGING_MASTER_KEY \
      -e BUILDKITE_BRANCH=$BUILDKITE_BRANCH \
      -e REVISION=$WEB_TAG \
      -v "$PWD/$PREVIEW_ASSET_CACHE_TARBALL:/tmp/$PREVIEW_ASSET_CACHE_TARBALL:ro" \
      --label assets_compiled=true \
      $WEB_REPO:web-$WEB_TAG \
      bash -c "cd /app \
        && tar -xzf /tmp/$PREVIEW_ASSET_CACHE_TARBALL \
        && chown -R app:app node_modules public \
        && rm -rf spec/" || return 1
    docker commit staging-assets-from-cache $WEB_REPO:staging-$WEB_TAG || return 1
    docker rm staging-assets-from-cache || :
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"

    # Re-sync assets to S3. The compiled files were already uploaded when the
    # cache entry was created, so this is a fast no-op sync — kept as a
    # safety net in case that earlier upload was interrupted. Best-effort:
    # the expensive part (the docker commit above) already succeeded, so a
    # transient S3 failure here is logged but never discards the committed
    # image or triggers the full recompile.
    #
    # This best-effort failure mode can't leave pages linking to a missing
    # stylesheet: a cache entry only exists after a full compile whose S3
    # upload succeeded (the push runs as a fatal step inside `make
    # build_staging`), so the fingerprinted pages Tailwind CSS named by the
    # image's manifest is already in the bucket before any image carrying
    # that manifest can be built from cache.
    logger "Syncing cached assets to S3"
    local container_id
    if container_id=$(docker run -d --entrypoint="bash" --volume /app $WEB_REPO:staging-$WEB_TAG); then
      if ! docker run --rm \
        -e AWS_ACCESS_KEY_ID=$GUM_AWS_ACCESS_KEY_ID \
        -e AWS_SECRET_ACCESS_KEY=$GUM_AWS_SECRET_ACCESS_KEY \
        -e ASSETS_S3_BUCKET=gumroad-staging-assets \
        --volumes-from $container_id \
        garland/aws-cli-docker \
        sh /app/docker/web/push_assets_to_s3.sh; then
        logger "S3 asset sync failed — continuing with the cached staging image (assets were already uploaded when the cache entry was created)"
      fi
      # -v also removes the anonymous /app volume the data container created,
      # so cache-hit builds don't leak a volume on the CI agent every deploy.
      docker rm -fv $container_id >/dev/null 2>&1 || true
    else
      # Even the data container for the sync couldn't be created — still fine.
      # The staging image is already committed and the assets were uploaded to
      # S3 when the cache entry was created, so skip the sync rather than
      # throwing away the committed image with a full recompile.
      logger "Could not start the S3 sync container — skipping the best-effort asset sync"
    fi
    return 0
  }

  if [[ $ASSET_CACHE_HIT == true ]]; then
    # A corrupt or incomplete cache entry must never fail the deploy — fall
    # back to the full compile (which then overwrites the bad entry).
    if ! build_staging_image_from_cache; then
      logger "Cache-hit image build failed — falling back to full asset compile"
      ASSET_CACHE_HIT=false
      docker rm -f staging-assets-from-cache 2>/dev/null || :
      rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    fi
  fi

  if [[ $ASSET_CACHE_HIT != true ]]; then
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

    # Populate the cache for the next push on this branch. Best-effort: a
    # failed save never fails the deploy.
    if preview_asset_cache_enabled; then
      preview_asset_cache_save "$ASSET_CACHE_TAG" "$WEB_REPO:staging-$WEB_TAG" || true
    fi
  fi

  push_image staging || exit 1
fi

# Raises the web clusters for the deploy's scale_up, timed to land a few minutes before
# it: soon enough for the new instances to boot (about 2.5 minutes), late enough that
# target tracking has not scaled the idle ones back in (about 5.5 minutes after a raise).
# A full compile ends about 3 minutes after the delay below; a cache hit starts it once its
# image is built. It never fails the compile. A compile that ends or fails before it starts
# cancels it; one that has started finishes its few-second raise within its own deadline.
PRESCALE_DELAY_SECONDS=${PRESCALE_DELAY_SECONDS:-210}
PRESCALE_SCRIPT=${PRESCALE_SCRIPT:-.buildkite/scripts/prescale_web_clusters.sh}
PRESCALE_PID=""
PRESCALE_LOG=$(mktemp)
start_web_prescale() {
  local delay=$1
  [[ $BUILDKITE_BRANCH == "main" && -z $PRESCALE_PID ]] || return 0
  logger "Pre-scaling the web clusters in ${delay}s"
  # Nothing here may hold the job's output open, or a stalled pre-scale would hold up the
  # compile the deploy waits for. Its log is printed when the compile ends.
  ( sleep "$delay" >/dev/null 2>&1; bash "$PRESCALE_SCRIPT" >"$PRESCALE_LOG" 2>&1 || true ) &
  PRESCALE_PID=$!
}
cancel_web_prescale() {
  [[ -z $PRESCALE_PID ]] || kill "$PRESCALE_PID" 2>/dev/null || true
  if [[ -s $PRESCALE_LOG ]]; then
    logger "Pre-scale log so far:"
    cat "$PRESCALE_LOG"
  fi
  rm -f "$PRESCALE_LOG"
}
trap cancel_web_prescale EXIT

# Keep in step with `make build_production` with PUSH_ASSETS=true.
push_production_assets() {
  local image=$1 container_id status=0
  container_id=$(docker run -d --entrypoint="bash" --volume /app "$image") || return 1
  docker run --rm \
    -e AWS_ACCESS_KEY_ID="$GUM_AWS_ACCESS_KEY_ID" \
    -e AWS_SECRET_ACCESS_KEY="$GUM_AWS_SECRET_ACCESS_KEY" \
    -e ASSETS_S3_BUCKET=gumroad-production-assets \
    --volumes-from "$container_id" \
    garland/aws-cli-docker \
    sh /app/docker/web/push_assets_to_s3.sh || status=$?
  docker rm -fv "$container_id" >/dev/null 2>&1 || true
  return $status
}

# On a cache hit, builds the production image from the web image and the files a
# full compile of the same inputs produced, and skips the compile. The container
# carries the same env and label as `make build_production`, because docker commit
# bakes them into the image. A full compile also leaves a warm Bootsnap cache from
# its Rails boot, which saves each production container about 3 s of boot, so the
# hit path precompiles one (about 4 s); if that fails, the image just boots cold. Returns non-zero for a full compile instead: a miss,
# a "no-cache" commit, or an image that could not be built. A failed S3 upload of
# a built image stops the build, as it does after a full compile.
build_production_image_from_main_asset_cache() {
  local PREVIEW_ASSET_CACHE_PREFIX=$MAIN_ASSET_CACHE_PREFIX
  local tag image=$WEB_REPO:production-$WEB_TAG
  [[ $BUILDKITE_BRANCH == "main" ]] || return 1
  if [[ ${BUILDKITE_MESSAGE:-} =~ no[-_.[:space:]]cache ]]; then
    logger "The commit message asks for no cache: running the full compile"
    return 1
  fi
  tag=$(main_asset_cache_tag)
  if ! preview_asset_cache_restore "$tag"; then
    logger "Main asset cache miss for tag $tag: running the full compile"
    return 1
  fi
  logger "Main asset cache hit for tag $tag: building $image from the cached files"
  docker rm -f production-assets-from-cache >/dev/null 2>&1 || :
  if ! docker run \
      --name production-assets-from-cache \
      --entrypoint="" \
      -e RAILS_ENV="production" \
      -e RACK_ENV="production" \
      -e DATABASE_HOST="db_test" \
      -e DATABASE_NAME="gumroad_test" \
      -e DATABASE_USERNAME="root" \
      -e DATABASE_PASSWORD="password" \
      -e RAILS_MASTER_KEY="$RAILS_PRODUCTION_MASTER_KEY" \
      -e DEVISE_SECRET_KEY="sample_secret_key" \
      -e BUILDKITE_BRANCH="$BUILDKITE_BRANCH" \
      -e REVISION="$WEB_TAG" \
      -v "$PWD/$PREVIEW_ASSET_CACHE_TARBALL:/tmp/$PREVIEW_ASSET_CACHE_TARBALL:ro" \
      --label assets_compiled=true \
      "$WEB_REPO:web-$WEB_TAG" \
      bash -c "set -e; cd /app; tar -xzf /tmp/$PREVIEW_ASSET_CACHE_TARBALL; for p in $MAIN_ASSET_CACHE_PATHS; do [ ! -e \"\$p\" ] || chown -R app:app \"\$p\"; done; rm -rf spec/; gosu app bundle exec bootsnap precompile --gemfile app/ lib/ config/ || echo 'bootsnap precompile failed; the image will boot with a cold cache'" \
    || ! docker commit production-assets-from-cache "$image"; then
    logger "Could not build $image from the cached files: running the full compile"
    docker rm -f production-assets-from-cache >/dev/null 2>&1 || :
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    return 1
  fi
  docker rm production-assets-from-cache >/dev/null 2>&1 || :
  rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
  start_web_prescale 0
  if ! push_production_assets "$image"; then
    logger "Uploading the production assets to S3 failed: stopping the build"
    exit 1
  fi
  if command -v buildkite-agent >/dev/null 2>&1; then
    printf 'Production assets served from the main asset cache (tag `%s`); the compile was skipped.\n' "$tag" \
      | buildkite-agent annotate --style info --context main-asset-cache-served 2>/dev/null || true
  fi
  record_main_asset_cache_outcome "$tag"
}

# main_asset_cache_save.sh reads this: an image built from the cache holds the cached
# files, so that step has nothing to compare or save. Every production attempt writes
# it, because build meta-data outlives a retry. Only a retry can find an earlier
# attempt's tag, so only a retry stops when its write fails: a stale tag would skip the
# save step's comparison of a full compile.
record_main_asset_cache_outcome() {
  [[ $BUILDKITE_BRANCH == "main" ]] && command -v buildkite-agent >/dev/null 2>&1 || return 0
  buildkite-agent meta-data set main-asset-cache-served "$1" >/dev/null 2>&1 && return 0
  if [[ ${BUILDKITE_RETRY_COUNT:-0} != 0 ]]; then
    logger "Could not record the main asset cache outcome on a retry: stopping, so the job retries"
    exit 1
  fi
}

if [[ $BUILDKITE_PARALLEL_JOB = 1 && ( $BUILDKITE_BRANCH == "main" || $BUILDKITE_BRANCH == comp-assets-* ) ]]; then
  if [[ -n ${CUSTOM_DOMAIN:-} ]]; then
    logger "CUSTOM_DOMAIN is set: a production build must not bake a preview domain into its assets"
    exit 1
  fi

  if ! build_production_image_from_main_asset_cache; then
    record_main_asset_cache_outcome none
    start_web_prescale "$PRESCALE_DELAY_SECONDS"
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
  fi

  push_image production || exit 1
fi
