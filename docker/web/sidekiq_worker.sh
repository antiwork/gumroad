#!/bin/bash

set -e

consul_put() {
  curl \
    --silent \
    --request PUT \
    --data $2 \
    http://docker-host.intranet:8500/v1/kv/$1 > /dev/null
}

cd /app

# Configured 20% chance to prioritize the 'mongo' queue before 'low'.
# This helps clear out 'mongo' jobs if the 'low' queue is blocked by external issues.
# Will help prevent the risk of Redis running out of memory.
if [ $((RANDOM % 100)) -lt 20 ]; then
  bundle exec sidekiq \
    -q critical \
    -q default \
    -q mongo \
    -q low
else
  bundle exec sidekiq \
    -q critical \
    -q default \
    -q low \
    -q mongo
fi
