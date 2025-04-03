#!/bin/bash

set -e

mkdir -p /etc/services.d/rpush && \
  cp /app/docker/web/service.d.templates/rpush_run /etc/services.d/rpush/run

# handoff to s6-overlay
exec /init
