#!/bin/bash

set -e

cd $APP_DIR

consul_put() {
  curl \
    --silent \
    --request PUT \
    --data $2 \
    http://localhost:8500/v1/kv/$1 > /dev/null
}

# Set default value for port
export PORT=3000

# For preview apps, use the Nomad-allocated port and register the app's address in consul for routing
if [[ $BRANCH_DEPLOYMENT == "true" ]]; then
  if [[ ! -z "$NOMAD_HOST_PORT_puma" ]]; then
    export PORT=$NOMAD_HOST_PORT_puma
    consul_put $CUSTOM_DOMAIN $NOMAD_ADDR_puma
  fi
fi

# Production/staging images already ran this in compile_assets.sh (docker commit).
# Re-running on every boot holds :3000 closed while nginx is already in ALB rotation.
if [[ ! -f app/javascript/utils/routes.js || ! -f public/pages-tailwind.css ]]; then
  echo "npm run setup"
  npm run setup
else
  echo "npm run setup skipped (outputs already in image)"
fi

exec bundle exec rails server -p $PORT
