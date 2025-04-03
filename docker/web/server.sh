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

# Send notification to Slack on branch app deployment
if [[ $BRANCH_DEPLOYMENT == "true" ]]; then
  if [[ ! -z "$NOMAD_HOST_PORT_puma" ]]; then
    export PORT=$NOMAD_HOST_PORT_puma
    consul_put $CUSTOM_DOMAIN $NOMAD_ADDR_puma
  fi
fi

echo "npm run setup"
npm run setup

exec bundle exec rails server -p $PORT
