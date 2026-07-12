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
LOCAL_DUMP=$(mktemp /tmp/prepared_test_db.XXXXXX.sql.gz)

# Extract the dump from the image without running it. `docker create` makes a
# stopped container we can copy files out of.
CONTAINER_ID=$(docker create "$IMAGE")
cleanup() {
  docker rm "$CONTAINER_ID" > /dev/null 2>&1 || true
  rm -f "$LOCAL_DUMP"
}
trap cleanup EXIT

if docker cp "$CONTAINER_ID:$DUMP_PATH_IN_IMAGE" "$LOCAL_DUMP" 2>/dev/null; then
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
  echo "No baked test database dump found in image — falling back to rake db:prepare"
  docker run --rm --entrypoint="" --network "$NETWORK" -e RAILS_ENV=test "$IMAGE" \
    bundle exec rake db:prepare
fi
