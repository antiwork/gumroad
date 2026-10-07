#!/bin/bash

source $APP_DIR/nomad/staging/deploy_branch/deploy_branch_common.sh

set -e

cd $APP_DIR

# Set CUSTOM_DOMAIN for preview app assets precompilation (never for an empty branch)
if [[ -n $BUILDKITE_BRANCH && $BUILDKITE_BRANCH != "main" && $BUILDKITE_BRANCH != comp-assets-* ]]; then
  base_domain="staging.gumroad.org"
  app_name=$(get_app_name $BUILDKITE_BRANCH)

  custom_domain="${app_name}.apps.${base_domain}"

  echo "Setting CUSTOM_DOMAIN: $custom_domain"
  export CUSTOM_DOMAIN=$custom_domain
fi

export PUPPETEER_SKIP_DOWNLOAD="true"

# vite_ruby's assets:precompile otherwise runs this same `npm ci` a second time.
export VITE_RUBY_SKIP_ASSETS_PRECOMPILE_INSTALL=true
NODE_ENV=development npm ci

# One Rails boot. js:export must run first: Vite reads routes.js. assets:precompile
# builds the pages Tailwind itself (lib/tasks/pages_tailwind.rake).
bundle exec rake js:export assets:precompile

remove_assets_dir() {
  ASSETS_DIRECTORY=$1
  if [ -d "$ASSETS_DIRECTORY" ]; then
    echo "Removing $ASSETS_DIRECTORY directory"
    rm -rf $ASSETS_DIRECTORY
  fi
}

remove_assets_dir /app/tmp/cache/assets/

# The image is docker-committed from this container, so anything left here ships.
rm -rf ~/.npm ~/.cache/node-gyp /tmp/node-compile-cache

# Production never runs npm again: server.sh skips `npm run setup` when its outputs exist.
# Staging keeps node_modules because a preview asset-cache hit restores public/ without
# routes.js, so its boot runs `npm run setup`.
if [[ $RAILS_ENV == "production" ]]; then
  remove_assets_dir /app/node_modules/
fi
