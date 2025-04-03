#!/bin/bash

source $APP_DIR/nomad/staging/deploy_branch/deploy_branch_common.sh

set -e

cd $APP_DIR

# Set CUSTOM_DOMAIN for branch app assets precompilation
if [[ $BUILDKITE_BRANCH == deploy-* ]]; then
  base_domain="staging.gumroad.org"
  app_name=$(get_app_name $BUILDKITE_BRANCH)

  custom_domain="${app_name}.apps.${base_domain}"

  echo "Setting CUSTOM_DOMAIN: $custom_domain"
  export CUSTOM_DOMAIN=$custom_domain
fi

export PUPPETEER_SKIP_DOWNLOAD="true"

npm install

npm run setup

bundle exec rake assets:precompile

remove_assets_dir() {
  ASSETS_DIRECTORY=$1
  if [ -d "$ASSETS_DIRECTORY" ]; then
    echo "Removing $ASSETS_DIRECTORY directory"
    rm -rf $ASSETS_DIRECTORY
  fi
}

remove_assets_dir /app/tmp/cache/assets/
