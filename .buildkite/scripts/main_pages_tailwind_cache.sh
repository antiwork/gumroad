#!/bin/bash
# shellcheck disable=SC2034 # read by the preview_asset_cache.sh helpers called below
# Caches the production compile's pages CSS (scripts/build_pages_tailwind.mjs) in S3.
# Its class list is fixed, so app code and views never change it, and a main build
# whose inputs did not change skips the Tailwind build. Only main writes entries;
# main and comp-assets-* builds read them. Source preview_asset_cache.sh first.

MAIN_PAGES_TAILWIND_CACHE_PREFIX="main-pages-tailwind"
MAIN_PAGES_TAILWIND_CACHE_VERSION="v1"
# The directory compile_assets.sh mounts into the compile container (Makefile,
# build_production) as /pages-tailwind-cache. It holds the restored tarball, and
# pages_tailwind.tar.gz.new after a build the cache did not have.
MAIN_PAGES_TAILWIND_CACHE_DIR=.main-pages-tailwind-cache

# The lockfile pins Tailwind and its typography plugin; docker/base pins Node.
main_pages_tailwind_cache_tag() {
  local tree_sha
  tree_sha=$(git ls-tree -r HEAD -- scripts/build_pages_tailwind.mjs app/javascript/stylesheets/pages_tailwind.css \
    lib/tasks/pages_tailwind.rake package.json package-lock.json .npmrc patches docker/base docker/web/compile_assets.sh \
    | sha1sum | cut -d " " -f1)
  echo "$tree_sha production $MAIN_PAGES_TAILWIND_CACHE_VERSION" | sha1sum | cut -d " " -f1
}

# Leaves pages_tailwind.tar.gz in the cache directory on a verified hit.
main_pages_tailwind_cache_restore() {
  local tag=$1
  (
    PREVIEW_ASSET_CACHE_PREFIX=$MAIN_PAGES_TAILWIND_CACHE_PREFIX
    PREVIEW_ASSET_CACHE_TARBALL=$MAIN_PAGES_TAILWIND_CACHE_DIR/pages_tailwind.tar.gz
    PREVIEW_ASSET_CACHE_CHECKSUM=$MAIN_PAGES_TAILWIND_CACHE_DIR/pages_tailwind.tar.gz.sha256
    preview_asset_cache_restore "$tag"
  )
}

# Best-effort: uploads the tarball the compile container wrote after the build,
# tarball first, then the checksum sidecar that restore verifies.
main_pages_tailwind_cache_save() {
  local tag=$1 tarball=$MAIN_PAGES_TAILWIND_CACHE_DIR/pages_tailwind.tar.gz.new
  [[ -s $tarball ]] || return 0
  (
    PREVIEW_ASSET_CACHE_PREFIX=$MAIN_PAGES_TAILWIND_CACHE_PREFIX
    checksum=$tarball.sha256
    sha256sum "$tarball" | cut -d " " -f1 > "$checksum"
    if preview_asset_cache_s3_cp "$tarball" "$(preview_asset_cache_url "$tag")" \
      && preview_asset_cache_s3_cp "$checksum" "$(preview_asset_cache_url "$tag").sha256"; then
      preview_asset_cache_logger "Saved the pages CSS for tag $tag"
    else
      preview_asset_cache_logger "Could not save the pages CSS for tag $tag"
    fi
  )
}
