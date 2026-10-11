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

if [ "$1" = "long" ]; then
  bundle exec sidekiq \
    -q long
else
  # `exports` is listed last: with strict queue order a big sales export only uses threads that
  # critical/default/low leave free, so it can't starve other `low` jobs.
  bundle exec sidekiq \
    -q critical \
    -q default \
    -q low \
    -q exports
fi
