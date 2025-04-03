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

bundle exec sidekiq \
  -q critical \
  -q default \
  -q low \
  -q mongo
