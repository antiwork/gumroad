#!/bin/bash

# Restore the prepared test database that the build job baked into the test
# image (see docker/ci/dump_test_db.sh for how it gets there).
#
# Each test shard boots its own empty MySQL service. Loading the baked dump
# takes seconds, versus the minutes `rake db:prepare` spends booting Rails
# and re-creating the schema + seeds from scratch on every one of the ~68
# shards.
#
# If the image does not contain a dump (for example an image built before
# this mechanism existed, still referenced through the content-addressed
# cache), we fall back to the old `rake db:prepare` path so the shard still
# works — just without the speedup.
#
# Usage: docker/ci/restore_test_db.sh <docker-network> <test-image>
#   <docker-network>  The compose network where this shard's db_test runs.
#   <test-image>      The web test image (may contain the baked dump).

set -euo pipefail

NETWORK=$1
IMAGE=$2

MYSQL_IMAGE=mysql:8.0.32
DUMP_PATH_IN_IMAGE=/app/db/prepared_test_db.sql.gz

# Register the cleanup trap before creating anything it needs to clean up, so
# a failure partway through setup (for example `docker create` erroring out)
# still removes whatever did get created.
CONTAINER_ID=""
LOCAL_DUMP=""
cleanup() {
  if [ -n "$CONTAINER_ID" ]; then
    docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
  fi
  if [ -n "$LOCAL_DUMP" ]; then
    rm -f "$LOCAL_DUMP"
  fi
}
trap cleanup EXIT

LOCAL_DUMP=$(mktemp /tmp/prepared_test_db.XXXXXX.sql.gz)

# Extract the dump from the image without running it. `docker create` makes a
# stopped container we can copy files out of.
CONTAINER_ID=$(docker create "$IMAGE")

# The dump must both exist in the image AND be a valid gzip file. A truncated
# or corrupt dump (say, from a build that got interrupted mid-copy) would
# otherwise make every retry of this step fail the same way; checking validity
# up front lets us fall back to `rake db:prepare` instead.
if docker cp "$CONTAINER_ID:$DUMP_PATH_IN_IMAGE" "$LOCAL_DUMP" 2>/dev/null \
    && gunzip -t "$LOCAL_DUMP" 2>/dev/null; then
  echo "Restoring baked test database dump ($(du -h "$LOCAL_DUMP" | cut -f1))..."
  # The mysql client runs from the same image the db_test service uses,
  # because the test image doesn't ship a mysql client binary. The dump was
  # taken with --add-drop-database, so re-running this (the CI step retries
  # on failure) cleanly replaces any partially restored database.
  gunzip -c "$LOCAL_DUMP" | docker run --rm -i --network "$NETWORK" \
    -e MYSQL_PWD=password "$MYSQL_IMAGE" \
    mysql --host=db_test --user=root
  echo "Test database restored from baked dump"
else
  echo "No usable baked test database dump in image (missing or corrupt) — falling back to rake db:prepare"
  docker run --rm --entrypoint="" --network "$NETWORK" -e RAILS_ENV=test "$IMAGE" \
    bundle exec rake db:prepare
fi
