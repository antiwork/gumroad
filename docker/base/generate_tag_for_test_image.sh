#!/bin/bash

set -e

# Compute a content-addressed tag for the web test image.
#
# Inputs (env):
#   BASE_TEST_SHA   Required. The content-addressed tag of web_base_test for
#                   this build (output of generate_tag_for_web_base_test.sh).
#
# The previous scheme used the commit SHA (`test-$REVISION`), forcing a
# rebuild on every commit even when the changes had no effect on the test
# image (e.g. doc-only or workflow-only commits). Here we hash only the
# files that actually contribute to the test image content, so identical
# content reuses the previously-pushed image via `docker manifest inspect`.
#
# Excluded paths (don't affect the test image content):
#   - .github/        workflow changes
#   - docs/           documentation
#   - autoresearch.*  autoresearch session files at repo root
#   - *.md            any markdown file (verified: no specs read .md fixtures,
#                     no app templates have .md extension; .md.erb still hashed)
#
# Inputs to the hash:
#   1. BASE_TEST_SHA — already content-addressed across base layer + Gemfile.lock
#   2. docker/web/Dockerfile.test — controls the build steps
#   3. The git tree listing (file paths + blob shas) for non-excluded paths,
#      which fingerprints all source code copied into the image (`COPY .`).

if [ -z "$BASE_TEST_SHA" ]; then
  echo "BASE_TEST_SHA is required" >&2
  exit 1
fi

dockerfile_sha=$(sha1sum docker/web/Dockerfile.test | cut -d " " -f1)

# Each `git ls-tree -r HEAD` entry is "<mode> blob <sha>\t<path>". The blob
# sha changes whenever a file's content changes, so hashing the filtered list
# fingerprints the relevant subset of the tree exactly.
tree_sha=$(git ls-tree -r HEAD \
  | awk -F'\t' '{
      path=$2
      if (path ~ /^\.github\//) next
      if (path ~ /^docs\//) next
      if (path ~ /^autoresearch\./) next
      if (path ~ /\.md$/) next
      print
    }' \
  | sha1sum | cut -d " " -f1)

echo "$BASE_TEST_SHA $dockerfile_sha $tree_sha" | sha1sum | cut -d " " -f1
