#!/bin/bash
# Shadow mode for a main-branch asset cache. It never changes what ships: the
# production image is already built and pushed when this step runs, and the
# deploy does not wait for it. On a hit it compares what the cache would have
# restored with the files in that image, one by one; on a miss it saves those
# files for the next commit with the same inputs. The cache may serve a deploy
# only after 30 hits with 0 mismatches.
#
# Exit 1 (a soft failure in the pipeline) only on a mismatch, so one stands out.
set -uo pipefail

source .buildkite/scripts/preview_asset_cache.sh
source .buildkite/scripts/deploy_relevance.sh
# A no-op commit builds no production image, so there is nothing to compare.
skip_if_production_noop "main_asset_cache_shadow.sh"

# Its own prefix and version, so entries never mix with preview ones. The
# preview helpers below read this prefix; this script runs in its own process.
PREVIEW_ASSET_CACHE_PREFIX="main-asset-cache"
MAIN_ASSET_CACHE_VERSION="v1"
# A production image has no node_modules, so it cannot rebuild routes.js or the
# JSON schemas at boot: a cache for main must carry them.
MAIN_ASSET_CACHE_PATHS="public/vite public/js public/pages-tailwind.css public/assets/pages public/pages-tailwind-manifest.json app/javascript/utils/routes.js app/javascript/utils/routes.d.ts app/javascript/json_schemas"

IMAGE="${ECR_REGISTRY}/gumroad/web:production-$(echo "$BUILDKITE_COMMIT" | cut -c1-12)"
# Relative, under the checkout: without a host aws CLI the S3 helper runs in a
# container that mounts only the current directory.
WORK=.main-asset-cache-shadow
rm -rf "$WORK" && mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# The branch is not in the key: main never sets CUSTOM_DOMAIN. The environment
# is, because RAILS_ENV picks the asset host baked into the bundle.
main_asset_cache_tag() {
  local tree_sha
  tree_sha=$(preview_asset_cache_inputs | sha1sum | cut -d " " -f1)
  echo "$tree_sha production $MAIN_ASSET_CACHE_VERSION" | sha1sum | cut -d " " -f1
}

# "sha256  path" for every file under the cached paths, in a stable order.
file_digests() {
  (cd "$1" && for p in $MAIN_ASSET_CACHE_PATHS; do [ -e "$p" ] && find "$p" -type f; done | LC_ALL=C sort | xargs -r sha256sum)
}

report() {
  local result=$1 detail=$2 style=${3:-info}
  local line="main-asset-cache-shadow result=$result tag=${TAG:-none} $detail"
  echo "$line"
  if command -v buildkite-agent >/dev/null 2>&1; then
    printf '%s\n' "$line" | buildkite-agent annotate --style "$style" --context main-asset-cache-shadow 2>/dev/null || true
  fi
}

pulled=false
for _ in 1 2 3; do
  docker pull "$IMAGE" >/dev/null && { pulled=true; break; }
  sleep 5
done
if [ "$pulled" != true ]; then
  report error "could not pull $IMAGE" warning
  exit 0
fi

TAG=$(main_asset_cache_tag)
mkdir -p "$WORK/real" "$WORK/cached"
if ! docker run --rm --entrypoint="" "$IMAGE" bash -c \
    "cd /app && paths=''; for p in $MAIN_ASSET_CACHE_PATHS; do [ -e \"\$p\" ] && paths=\"\$paths \$p\"; done; tar -cf - \$paths" \
    | tar -xf - -C "$WORK/real"; then
  report error "could not read the compiled files from $IMAGE" warning
  exit 0
fi
file_digests "$WORK/real" > "$WORK/real.sha256"
files=$(wc -l < "$WORK/real.sha256" | tr -d ' ')
# Never compare against, or save, an empty set.
if [ "$files" = "0" ]; then
  report error "no compiled files in $IMAGE" warning
  exit 0
fi

if preview_asset_cache_restore "$TAG"; then
  tar -xzf "$PREVIEW_ASSET_CACHE_TARBALL" -C "$WORK/cached"
  rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
  file_digests "$WORK/cached" > "$WORK/cached.sha256"
  if cmp -s "$WORK/real.sha256" "$WORK/cached.sha256"; then
    report hit "files=$files mismatched=0" success
    exit 0
  fi
  differing=$(diff "$WORK/cached.sha256" "$WORK/real.sha256" | grep -c '^[<>]')
  report mismatch "files=$files differing_lines=$differing first: $(diff "$WORK/cached.sha256" "$WORK/real.sha256" | grep '^[<>]' | head -5 | tr '\n' ';')" error
  exit 1
fi

# A miss: save these files, so the next commit with the same inputs is a hit.
tarball="$WORK/main-asset-cache.tar.gz"
present=()
for p in $MAIN_ASSET_CACHE_PATHS; do [ -e "$WORK/real/$p" ] && present+=("$p"); done
tar -czf "$tarball" -C "$WORK/real" "${present[@]}"
sha256sum "$tarball" | cut -d " " -f1 > "$tarball.sha256"
# The sidecar goes up after the tarball: restore treats a tarball without one
# as a miss.
if preview_asset_cache_s3_cp "$tarball" "$(preview_asset_cache_url "$TAG")" \
  && preview_asset_cache_s3_cp "$tarball.sha256" "$(preview_asset_cache_url "$TAG").sha256"; then
  report miss "files=$files saved=true"
else
  report miss "files=$files saved=false" warning
fi
exit 0
