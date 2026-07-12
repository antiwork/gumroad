#!/bin/bash

# Dump the prepared test database to a gzipped SQL file so the CI build job
# can bake it into the test image.
#
# Context: the build job runs `rake db:setup` once while building the test
# image, which leaves a fully prepared `gumroad_test` database (schema +
# seeds + schema_migrations rows) in the compose stack's MySQL service.
# Historically every test shard then re-created that same database from
# scratch with `rake db:prepare` — a fixed cost paid ~68 times per run.
# Instead, the build job calls this script to snapshot the prepared database,
# copies the dump into the image before `docker commit`, and each shard
# restores the dump (seconds) via docker/ci/restore_test_db.sh.
#
# The dump always matches the code in the image: the test image tag is
# content-addressed over the git tree (including db/schema.rb, db/seeds and
# this script), so any change that affects the prepared database produces a
# new tag and a fresh image + dump.
#
# Usage: docker/ci/dump_test_db.sh <docker-network> <output-file>
#   <docker-network>  The compose network where the db_test service runs.
#   <output-file>     Path on the host for the gzipped dump.
#
# Runs the MySQL client from the same mysql image the db_test service uses,
# because the test image itself doesn't ship a mysql client binary.

set -euo pipefail

NETWORK=$1
OUTPUT=$2

MYSQL_IMAGE=mysql:8.0.32

# --add-drop-database makes the dump idempotent to restore: the CI step that
# restores it runs under a retry wrapper, so a second attempt must be able to
# cleanly replace a partially restored database.
docker run --rm --network "$NETWORK" -e MYSQL_PWD=password "$MYSQL_IMAGE" \
  mysqldump \
    --host=db_test \
    --user=root \
    --databases gumroad_test \
    --add-drop-database \
    --single-transaction \
    --set-gtid-purged=OFF \
    --quick \
  | gzip > "$OUTPUT"

echo "Dumped prepared test database to $OUTPUT ($(du -h "$OUTPUT" | cut -f1))"
