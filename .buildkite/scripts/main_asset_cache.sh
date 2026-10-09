#!/bin/bash
# shellcheck disable=SC2034 # the variables are read by the scripts that source this file
# The main-branch asset cache, shared by the production compile (which serves
# from it) and the save step (which fills and checks it). Source
# preview_asset_cache.sh first: the tag reuses its input list.

MAIN_ASSET_CACHE_PREFIX="main-asset-cache"
MAIN_ASSET_CACHE_VERSION="v1"
# A production image has no node_modules, so it cannot rebuild routes.js or the
# JSON schemas at boot: a cache for main must carry them.
MAIN_ASSET_CACHE_PATHS="public/vite public/js public/pages-tailwind.css public/assets/pages public/pages-tailwind-manifest.json app/javascript/utils/routes.js app/javascript/utils/routes.d.ts app/javascript/json_schemas"

# The branch is not in the key: main never sets CUSTOM_DOMAIN. The environment
# is, because RAILS_ENV picks the asset host baked into the bundle.
main_asset_cache_tag() {
  local tree_sha
  tree_sha=$(preview_asset_cache_inputs | sha1sum | cut -d " " -f1)
  echo "$tree_sha production $MAIN_ASSET_CACHE_VERSION" | sha1sum | cut -d " " -f1
}
