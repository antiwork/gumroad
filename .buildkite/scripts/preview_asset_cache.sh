#!/bin/bash
# Content-addressed cache of compiled preview-app assets.
#
# Compiling assets is the slowest part of every preview-app deploy (~11 of the
# ~13 minutes the Compile Assets step takes): npm install, a Rails boot for
# js:export, the main Vite build, and the two widget builds. None of that work
# changes unless the files that feed it change, yet the pipeline redid all of
# it on every push — including backend-only pushes and "merge main into the
# preview branch" refreshes.
#
# This helper caches the compiled artifacts (node_modules, public/vite,
# public/js, the pages Tailwind build and its manifest) in S3, keyed on a hash of every input
# that feeds the compile. On a hit, compile_assets.sh restores the artifacts
# into a fresh web-image container and commits that as the staging image,
# skipping npm install / js:export / Vite entirely. On a miss it builds
# normally and uploads the artifacts for next time.
#
# The cache key includes the branch name because js:export bakes the preview
# app's domain (CUSTOM_DOMAIN, derived from the branch) into routes.js, which
# the Vite bundle then inlines — identical sources on two different branches
# compile to different assets.
#
# Preview-only by design: main and comp-assets-* builds (the production and
# staging deploy paths) never read or write this cache. Pushing a commit whose
# message contains "no-cache" bypasses it, mirroring branch_cache_setup in
# ci_scripts/helper.sh.

PREVIEW_ASSET_CACHE_BUCKET="buildkite-branch-cache"
PREVIEW_ASSET_CACHE_PREFIX="preview-asset-cache"
# Bump to invalidate every existing cache entry at once (e.g. after changing
# the artifact list below or discovering a missing hash input).
PREVIEW_ASSET_CACHE_VERSION="v1"
PREVIEW_ASSET_CACHE_TARBALL="preview-asset-cache.tar.gz"
# Local scratch file for the SHA-256 sidecar (see restore/save below).
PREVIEW_ASSET_CACHE_CHECKSUM="preview-asset-cache.tar.gz.sha256"

preview_asset_cache_logger() {
  echo -e "\033[0;32m$(date '+%Y/%m/%d %H:%M:%S') preview_asset_cache.sh: $1\033[0m"
}

# Everything that can change the output of `docker/web/compile_assets.sh`.
# Kept deliberately broad (vendored assets, tracked public files, the
# base-image definition that pins the Node version, the Makefile recipe the
# cache-hit path mirrors, and these two buildkite scripts themselves — the
# cache-hit image bakes in env vars defined in
# .buildkite/scripts/compile_assets.sh, so changing them must invalidate
# existing entries): a false miss costs one full compile; a false hit serves
# stale assets on a preview app.
#
# config/ is keyed on the subset the compile actually reads, not the whole
# directory — hashing all of config/ made every runtime-only initializer
# toggle (QA spoofs, feature constants, rate limits) a false miss that cost a
# 13-minute compile. The compile touches config/ through exactly three
# channels:
#   1. `rails js:export` (lib/tasks/js_export.rake) boots Rails and serializes
#      the routes via JsRoutes — the output depends on the routes files, the
#      constants they reference (all defined in config/domain.rb), the
#      JsRoutes initializer, and the boot plumbing that loads them. "Boot
#      plumbing" includes every file config/application.rb require_relatives
#      directly (config/redis.rb, lib/catch_bad_request_errors.rb,
#      lib/utilities/global_config.rb) — they run at boot before js:export, so
#      they're keyed even though today's versions don't shape the output.
#   2. Vite reads config/vite.json plus the plugins under config/vite/.
#   3. app/javascript imports config/currencies.json directly.
# Nothing else under config/ can reach the compiled artifacts: the other
# initializers, locales, and service configs (database/mongo/puma/
# sidekiq/certs) only affect runtime behavior. If you add a new compile-time
# read of config/ — a JS `import` from config/, a new file consumed by
# js:export or the Vite configs, or a routes-file reference to a constant
# defined outside config/domain.rb — add its path here.
preview_asset_cache_inputs() {
  git ls-tree -r HEAD -- \
    app/assets \
    app/javascript \
    config/routes.rb \
    config/routes \
    config/domain.rb \
    config/application.rb \
    config/boot.rb \
    config/environment.rb \
    config/environments \
    config/redis.rb \
    lib/catch_bad_request_errors.rb \
    lib/utilities/global_config.rb \
    config/initializers/js-routes.rb \
    config/vite.json \
    config/vite \
    config/currencies.json \
    lib/json_schemas \
    lib/tasks \
    Rakefile \
    public \
    vendor/assets \
    patches \
    scripts/build_pages_tailwind.mjs \
    docker/base \
    docker/web/compile_assets.sh \
    docker/web/push_assets_to_s3.sh \
    .buildkite/scripts/compile_assets.sh \
    .buildkite/scripts/preview_asset_cache.sh \
    Makefile \
    package.json \
    package-lock.json \
    .npmrc \
    tsconfig.json \
    vite.config.ts \
    vite.config.widget.ts \
    postcss.config.js \
    Gemfile.lock \
    .ruby-version
}

preview_asset_cache_tag() {
  local tree_sha
  tree_sha=$(preview_asset_cache_inputs | sha1sum | cut -d " " -f1)
  echo "$tree_sha $BUILDKITE_BRANCH $PREVIEW_ASSET_CACHE_VERSION" | sha1sum | cut -d " " -f1
}

preview_asset_cache_enabled() {
  # Preview branches only — never the main/staging/production asset paths.
  [[ -n $BUILDKITE_BRANCH ]] || return 1
  [[ $BUILDKITE_BRANCH != "main" ]] || return 1
  [[ $BUILDKITE_BRANCH != comp-assets-* ]] || return 1
  # Same escape hatch as the branch cache in ci_scripts/helper.sh (which
  # matches "no.cache" with a regex wildcard dot; here the separator is
  # spelled out so an unrelated word like "noXcache" can't disable the cache).
  [[ ! $BUILDKITE_MESSAGE =~ no[-_.[:space:]]cache ]] && return 0
  return 1
}

preview_asset_cache_url() {
  echo "s3://$PREVIEW_ASSET_CACHE_BUCKET/$PREVIEW_ASSET_CACHE_PREFIX/$1.tar.gz"
}

# Copies between S3 and a local file. The Buildkite preview agents do all
# their S3 work through the garland/aws-cli-docker image (see
# docker/web/push_assets_to_s3.sh) rather than a host-installed aws CLI, so
# prefer host aws when present but fall back to the container.
preview_asset_cache_s3_cp() {
  local src=$1 dst=$2
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID=$GUM_AWS_ACCESS_KEY_ID \
      AWS_SECRET_ACCESS_KEY=$GUM_AWS_SECRET_ACCESS_KEY \
      aws s3 cp "$src" "$dst"
  else
    docker run --rm \
      -e AWS_ACCESS_KEY_ID=$GUM_AWS_ACCESS_KEY_ID \
      -e AWS_SECRET_ACCESS_KEY=$GUM_AWS_SECRET_ACCESS_KEY \
      -v "$PWD:/workdir" \
      -w /workdir \
      garland/aws-cli-docker \
      aws s3 cp "$src" "$dst"
  fi
}

# Downloads the tarball for the current tag and verifies it against the
# SHA-256 sidecar uploaded alongside it. Returns non-zero (a miss) when the
# object doesn't exist, S3 is unreachable, the sidecar is missing, or the
# checksum doesn't match — the caller falls back to a full compile either way.
#
# The check matters because the tarball is extracted into a container that
# gets committed as the staging image: a truncated download or a tampered
# object must never make it that far. (The sidecar proves the tarball is the
# one this pipeline uploaded, byte for byte; keeping the bucket write-locked
# to CI is what proves who uploaded it.)
preview_asset_cache_restore() {
  local tag=$1
  rm -f "$PREVIEW_ASSET_CACHE_TARBALL" "$PREVIEW_ASSET_CACHE_CHECKSUM"
  preview_asset_cache_s3_cp "$(preview_asset_cache_url "$tag")" "$PREVIEW_ASSET_CACHE_TARBALL" || return 1

  if ! preview_asset_cache_s3_cp "$(preview_asset_cache_url "$tag").sha256" "$PREVIEW_ASSET_CACHE_CHECKSUM"; then
    preview_asset_cache_logger "No checksum sidecar for tag $tag — treating as a cache miss"
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    return 1
  fi

  local expected actual
  expected=$(tr -d '[:space:]' < "$PREVIEW_ASSET_CACHE_CHECKSUM")
  actual=$(sha256sum "$PREVIEW_ASSET_CACHE_TARBALL" | cut -d " " -f1)
  rm -f "$PREVIEW_ASSET_CACHE_CHECKSUM"
  if [[ -z $expected || $expected != "$actual" ]]; then
    preview_asset_cache_logger "Checksum mismatch for tag $tag — treating as a cache miss"
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    return 1
  fi
}

# Extracts the compiled artifacts out of the freshly built staging image and
# uploads them. Best-effort: a failed save must never fail the build, so call
# this with `|| true`.
preview_asset_cache_save() {
  local tag=$1
  local image=$2
  preview_asset_cache_logger "Saving compiled assets from $image for tag $tag"
  # gzip -1: node_modules dominates the tarball and compresses slowly at the
  # default level; speed matters more than a few percent of S3 storage.
  if ! docker run --rm --entrypoint="" "$image" \
    bash -c 'set -o pipefail; cd /app && paths=""; for p in node_modules public/vite public/js public/pages-tailwind.css public/assets/pages public/pages-tailwind-manifest.json; do [ -e "$p" ] && paths="$paths $p"; done; tar -cf - $paths | gzip -1' \
    > "$PREVIEW_ASSET_CACHE_TARBALL"; then
    preview_asset_cache_logger "Failed to extract assets from $image; skipping cache save"
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    return 1
  fi

  # The sidecar is what restore verifies before extracting the tarball into
  # the staging image. Upload it after the tarball: restore fetches the
  # tarball first, so it can never see a sidecar without its tarball, and a
  # tarball without a sidecar is treated as a miss.
  sha256sum "$PREVIEW_ASSET_CACHE_TARBALL" | cut -d " " -f1 > "$PREVIEW_ASSET_CACHE_CHECKSUM"
  if preview_asset_cache_s3_cp "$PREVIEW_ASSET_CACHE_TARBALL" "$(preview_asset_cache_url "$tag")" \
    && preview_asset_cache_s3_cp "$PREVIEW_ASSET_CACHE_CHECKSUM" "$(preview_asset_cache_url "$tag").sha256"; then
    preview_asset_cache_logger "Uploaded asset cache for tag $tag"
  else
    preview_asset_cache_logger "Failed to upload asset cache for tag $tag"
  fi
  rm -f "$PREVIEW_ASSET_CACHE_TARBALL" "$PREVIEW_ASSET_CACHE_CHECKSUM"
}
