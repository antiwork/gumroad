#!/bin/bash
# Fills the main-branch asset cache that compile_assets.sh serves from. It never
# changes what ships: the production image is already built and pushed when this
# step runs, and the deploy does not wait for it. On a miss it saves that image's
# compiled files for the next commit with the same inputs. When the compile ran
# although an entry exists (a no-cache commit, a failed cache build), it compares the
# entry with the real compile, one file at a time. A build served from the cache
# holds the cached files, so the step only records the hit.
#
# Exit 1 (a soft failure in the pipeline) only on a mismatch, so one stands out.
set -uo pipefail

source .buildkite/scripts/preview_asset_cache.sh
source .buildkite/scripts/main_asset_cache.sh
source .buildkite/scripts/deploy_relevance.sh
# A no-op commit builds no production image, so there is nothing to compare.
skip_if_production_noop "main_asset_cache_save.sh"

# Its own prefix, so entries never mix with preview ones. The preview helpers
# read this prefix; this script runs in its own process.
PREVIEW_ASSET_CACHE_PREFIX="$MAIN_ASSET_CACHE_PREFIX"

IMAGE="${ECR_REGISTRY}/gumroad/web:production-$(echo "$BUILDKITE_COMMIT" | cut -c1-12)"
# Relative, under the checkout: without a host aws CLI the S3 helper runs in a
# container that mounts only the current directory.
WORK=.main-asset-cache-save
rm -rf "$WORK" && mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

# "sha256  path" for every file under the cached paths, in a stable order.
file_digests() {
  (cd "$1" && for p in $MAIN_ASSET_CACHE_PATHS; do [ -e "$p" ] && find "$p" -type f; done | LC_ALL=C sort | xargs -r sha256sum)
}

# sha256sum prints a 64-character digest and two spaces before the path.
paths_of() { cut -c67- "$1"; }
# Two builds of one commit write identical JavaScript but slightly different
# `mappings` in its source maps. A cached map still maps that JavaScript, so a
# map that differs is counted, and a map that is missing or extra is a mismatch.
without_maps() { grep -v '\.map$' "$1" || true; }

report() {
  local result=$1 detail=$2 style=${3:-info}
  local line="main-asset-cache-save result=$result tag=${TAG:-none} $detail"
  echo "$line"
  if command -v buildkite-agent >/dev/null 2>&1; then
    printf '%s\n' "$line" | buildkite-agent annotate --style "$style" --context main-asset-cache-save 2>/dev/null || true
  fi
}

# compile_assets.sh writes the tag it served, or "none" after a full compile.
served=$(buildkite-agent meta-data get main-asset-cache-served 2>/dev/null) || served=""
if [ -n "$served" ] && [ "$served" != none ]; then
  TAG=$served
  report served "the image was built from the cache"
  exit 0
fi

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
  if ! tar -xzf "$PREVIEW_ASSET_CACHE_TARBALL" -C "$WORK/cached"; then
    rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
    report error "could not extract the cached files" warning
    exit 0
  fi
  rm -f "$PREVIEW_ASSET_CACHE_TARBALL"
  file_digests "$WORK/cached" > "$WORK/cached.sha256"
  differences=$({
    diff <(paths_of "$WORK/cached.sha256") <(paths_of "$WORK/real.sha256")
    diff <(without_maps "$WORK/cached.sha256") <(without_maps "$WORK/real.sha256")
  } | grep '^[<>]')
  if [ -z "$differences" ]; then
    maps_differing=$(diff "$WORK/cached.sha256" "$WORK/real.sha256" | grep -c '^>')
    report hit "files=$files mismatched=0 maps_differing=$maps_differing" success
    exit 0
  fi
  report mismatch "files=$files differing_lines=$(grep -c . <<<"$differences") first: $(head -5 <<<"$differences" | tr '\n' ';')" error
  exit 1
fi

tarball="$WORK/main-asset-cache.tar.gz"
present=()
for p in $MAIN_ASSET_CACHE_PATHS; do [ -e "$WORK/real/$p" ] && present+=("$p"); done
# A partial archive would upload with a matching checksum and read as a
# mismatch later.
if ! tar -czf "$tarball" -C "$WORK/real" "${present[@]}"; then
  report error "could not archive the compiled files" warning
  exit 0
fi
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
