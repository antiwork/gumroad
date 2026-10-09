#!/bin/bash
# `check && ok || fail` is safe here: ok never fails.
# shellcheck disable=SC2015
# Harness for the production path of compile_assets.sh: runs the real script
# against stub docker, make, aws and buildkite-agent binaries, with a local
# directory as the S3 bucket. Run from the repo root:
# .buildkite/scripts/main_asset_cache_compile_test.sh
set -uo pipefail

SCRIPT=.buildkite/scripts/compile_assets.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

mkdir -p "$WORK/bin"
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/bash
echo "docker $*" >> "$CALLS"
case "$1" in
  images) echo image-id ;;
  run)
    if [[ " $* " == *" --name production-assets-from-cache "* ]]; then
      mount=$(printf '%s\n' "$@" | grep -m1 ':/tmp/preview-asset-cache.tar.gz:ro' | cut -d: -f1)
      [ -f "$mount" ] && echo "tarball-mounted" >> "$CALLS"
      exit "${RUN_RC:-0}"
    fi
    [[ " $* " == *" -d "* ]] && { echo container-id; exit 0; }
    [[ " $* " == *"push_assets_to_s3.sh"* ]] && { sleep "${S3_SECONDS:-0}"; exit "${S3_RC:-0}"; }
    exit 0 ;;
  commit) exit "${COMMIT_RC:-0}" ;;
  rm|push|pull) exit 0 ;;
  *) exit 0 ;;
esac
STUB
cat > "$WORK/bin/make" <<'STUB'
#!/bin/bash
echo "make $*" >> "$CALLS"
sleep "${MAKE_SECONDS:-0}"
STUB
# Stands in for prescale_web_clusters.sh, so no case reaches AWS.
cat > "$WORK/prescale" <<'STUB'
echo "prescale" >> "$CALLS"
echo "prescale: raised the web clusters"
sleep "${PRESCALE_SECONDS:-0}"
STUB
cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
[ "$1 $2" = "s3 cp" ] || exit 1
src=$3 dst=$4
to_path() { echo "$BUCKET_DIR/${1#s3://}"; }
case "$src" in
  s3://*) [ -f "$(to_path "$src")" ] || exit 1; cp "$(to_path "$src")" "$dst" ;;
  *) mkdir -p "$(dirname "$(to_path "$dst")")"; cp "$src" "$(to_path "$dst")" ;;
esac
STUB
cat > "$WORK/bin/buildkite-agent" <<'STUB'
#!/bin/bash
case "$1 $2" in
  "meta-data set") [ "${META_SET_FAIL:-}" = 1 ] && { echo "meta-data-failed $3=$4" >> "$CALLS"; exit 1; }; echo "meta-data $3=$4" >> "$CALLS" ;;
  *) cat >> "$ANNOTATIONS" ;;
esac
STUB
chmod +x "$WORK/bin/"*

export BUILDKITE_COMMIT=0123456789abcdef0123 ECR_REGISTRY=ecr.example FORCE_DEPLOY=1 \
  GUM_AWS_ACCESS_KEY_ID=x GUM_AWS_SECRET_ACCESS_KEY=y RAILS_PRODUCTION_MASTER_KEY=k BUILDKITE_BUILD_NUMBER=1
TAG=$(BUILDKITE_BRANCH=main bash -c 'source .buildkite/scripts/preview_asset_cache.sh; source .buildkite/scripts/main_asset_cache.sh; main_asset_cache_tag')
ENTRY="$WORK/bucket/buildkite-branch-cache/main-asset-cache/$TAG.tar.gz"

seed_cache() {
  rm -rf "$WORK/bucket"; mkdir -p "$(dirname "$ENTRY")" "$WORK/files/public/vite"
  echo bundle > "$WORK/files/public/vite/app.js"
  tar -czf "$ENTRY" -C "$WORK/files" public
  sha256sum "$ENTRY" | cut -d " " -f1 > "$ENTRY.sha256"
}

run_script() {
  : > "$WORK/calls"; : > "$WORK/annotations"
  PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" BUCKET_DIR="$WORK/bucket" ANNOTATIONS="$WORK/annotations" \
    BUILDKITE_BRANCH=main BUILDKITE_PARALLEL_JOB=1 BUILDKITE_MESSAGE="Change something" \
    PRESCALE_SCRIPT="$WORK/prescale" \
    env "$@" bash "$SCRIPT" > "$WORK/out" 2>&1
}

compiled() { grep -q "^make build_production" "$WORK/calls"; }
served() { grep -q "^docker commit production-assets-from-cache ecr.example/gumroad/web:production-0123456789ab" "$WORK/calls"; }
pushed() { grep -q "^docker push ecr.example/gumroad/web:production-0123456789ab" "$WORK/calls"; }
uploaded() { grep -q "push_assets_to_s3.sh" "$WORK/calls"; }

echo "compile_assets.sh production path"

seed_cache; run_script; rc=$?
[ $rc = 0 ] && served && ! compiled && uploaded && pushed && ok "a hit builds the image from the cache, uploads the assets and pushes it, with no compile" || fail "hit (rc=$rc): $(cat "$WORK/out" | tail -3)"
grep -q "tarball-mounted" "$WORK/calls" && ok "the verified tarball is mounted into the image build" || fail "tarball not mounted"
grep -q -- "-e RAILS_ENV=production" "$WORK/calls" && grep -q -- "--label assets_compiled=true" "$WORK/calls" && grep -q -- "-e REVISION=0123456789ab" "$WORK/calls" \
  && ok "the image carries the same env and label as make build_production" || fail "image env or label"
grep -q "gosu app bundle exec bootsnap precompile --gemfile app/ lib/ config/ ||" "$WORK/calls" \
  && ok "the image gets a warm Bootsnap cache, best-effort, as the app user" || fail "no Bootsnap precompile in the image build"
grep -q "$TAG" "$WORK/annotations" && ok "a hit is annotated with its tag" || fail "hit not annotated"
grep -q "^meta-data main-asset-cache-served=$TAG" "$WORK/calls" && ok "a hit records its tag for the save step" || fail "hit tag not recorded"
[ ! -e preview-asset-cache.tar.gz ] && ok "it leaves no tarball behind" || fail "tarball left behind"

rm -rf "$WORK/bucket"; run_script; rc=$?
[ $rc = 0 ] && compiled && ! served && pushed && ok "a miss runs the full compile" || fail "miss (rc=$rc)"
grep -q "^meta-data main-asset-cache-served=none" "$WORK/calls" && ok "a miss records that nothing was served, replacing an earlier attempt's tag" || fail "a miss did not record none"

rm -rf "$WORK/bucket"; run_script META_SET_FAIL=1; rc=$?
[ $rc = 0 ] && compiled && pushed && ok "a first attempt compiles even when the outcome cannot be recorded" || fail "first attempt with a failed record (rc=$rc)"

rm -rf "$WORK/bucket"; run_script META_SET_FAIL=1 BUILDKITE_RETRY_COUNT=1; rc=$?
[ $rc != 0 ] && ! compiled && ! pushed && ok "a retry that cannot replace an earlier outcome stops, so the job retries" || fail "retry with a failed record (rc=$rc)"

seed_cache; run_script META_SET_FAIL=1; rc=$?
[ $rc = 0 ] && served && ! compiled && pushed && ok "a first-attempt hit still serves from the cache when its outcome cannot be recorded" || fail "first-attempt hit with a failed record (rc=$rc)"

seed_cache; run_script META_SET_FAIL=1 BUILDKITE_RETRY_COUNT=1; rc=$?
[ $rc != 0 ] && ! compiled && ! pushed && [ "$(grep -c "^meta-data" "$WORK/calls")" = 1 ] && grep -q "^meta-data-failed main-asset-cache-served=$TAG" "$WORK/calls" \
  && ok "a retried hit that cannot record its outcome stops at once, before any fallback or push" || fail "retried hit with a failed record (rc=$rc): $(grep "^meta-data" "$WORK/calls")"

rm -rf "$WORK/bucket"; run_script META_SET_FAIL=1 BUILDKITE_RETRY_COUNT=1 BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && compiled && pushed && ! grep -q "^meta-data" "$WORK/calls" \
  && ok "a comp-assets retry records nothing and never stops on it" || fail "comp-assets retry (rc=$rc)"

seed_cache; echo junk >> "$ENTRY"; run_script; rc=$?
[ $rc = 0 ] && compiled && ! served && ok "a tarball that fails its checksum runs the full compile" || fail "bad checksum (rc=$rc)"

seed_cache; run_script RUN_RC=1; rc=$?
[ $rc = 0 ] && compiled && ! uploaded && pushed && ok "an image that cannot be built from the cache falls back to the full compile" || fail "image build failure (rc=$rc)"
grep -q "Pre-scaling the web clusters in 210s" "$WORK/out" && ! grep -q "Pre-scaling the web clusters in 0s" "$WORK/out" \
  && ok "the fallback compile pre-scales on the full compile's delay" || fail "fallback pre-scale: $(grep -i pre-scal "$WORK/out")"

seed_cache; run_script COMMIT_RC=1; rc=$?
[ $rc = 0 ] && compiled && grep -q "Pre-scaling the web clusters in 210s" "$WORK/out" && ! grep -q "Pre-scaling the web clusters in 0s" "$WORK/out" \
  && ok "a cache image that fails to commit pre-scales only on the fallback compile's delay" || fail "commit failure pre-scale (rc=$rc): $(grep -i pre-scal "$WORK/out")"

seed_cache; run_script S3_RC=1; rc=$?
[ $rc != 0 ] && ! pushed && ! compiled && ok "a failed S3 upload stops the build before the image is pushed" || fail "S3 failure (rc=$rc)"

seed_cache; run_script CUSTOM_DOMAIN=preview.example.com; rc=$?
[ $rc != 0 ] && ! compiled && ! served && ok "CUSTOM_DOMAIN on the production path stops the build" || fail "CUSTOM_DOMAIN (rc=$rc)"

seed_cache; run_script BUILDKITE_MESSAGE="Fix a thing [no-cache]"; rc=$?
[ $rc = 0 ] && compiled && ! served && ok "a no-cache commit runs the full compile" || fail "no-cache (rc=$rc)"

seed_cache; run_script BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && compiled && ! served && ok "only main is served from the cache" || fail "comp-assets branch (rc=$rc)"

# The pre-scale runs in the background, so these cases wait out a short delay.
prescaled() { sleep 2; grep -q "^prescale" "$WORK/calls"; }

seed_cache; run_script S3_SECONDS=2; rc=$?
[ $rc = 0 ] && served && grep -q "^prescale" "$WORK/calls" && grep -q "Pre-scaling the web clusters in 0s" "$WORK/out" \
  && ok "a hit pre-scales the web clusters once its image is built, during the S3 upload" || fail "hit pre-scale (rc=$rc): $(grep -i pre-scal "$WORK/out")"
commit_line=$(grep -n "^docker commit production-assets-from-cache" "$WORK/calls" | cut -d: -f1)
prescale_line=$(grep -n "^prescale" "$WORK/calls" | cut -d: -f1)
[ -n "$commit_line" ] && [ -n "$prescale_line" ] && [ "$prescale_line" -gt "$commit_line" ] \
  && ok "the hit pre-scale starts after the image commit" || fail "pre-scale before the commit: $(cat "$WORK/calls")"

rm -rf "$WORK/bucket"; run_script; rc=$?
[ $rc = 0 ] && grep -q "Pre-scaling the web clusters in 210s" "$WORK/out" && ok "a full compile pre-scales the web clusters 210 s after it starts" || fail "miss pre-scale delay (rc=$rc): $(grep -i pre-scal "$WORK/out")"

rm -rf "$WORK/bucket"; run_script PRESCALE_DELAY_SECONDS=1 MAKE_SECONDS=3; rc=$?
[ $rc = 0 ] && prescaled && ok "the pre-scale runs once its delay passes during the compile" || fail "pre-scale did not run (rc=$rc)"
grep -q "prescale: raised the web clusters" "$WORK/out" && ok "the pre-scale's log is printed when the compile ends" || fail "pre-scale log missing: $(tail -3 "$WORK/out")"

seed_cache; : > "$WORK/calls"; started=$SECONDS
PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" BUCKET_DIR="$WORK/bucket" ANNOTATIONS="$WORK/annotations" \
  BUILDKITE_BRANCH=main BUILDKITE_PARALLEL_JOB=1 BUILDKITE_MESSAGE="Change something" \
  PRESCALE_SCRIPT="$WORK/prescale" PRESCALE_SECONDS=8 bash "$SCRIPT" 2>&1 | cat > "$WORK/out"
[ $((SECONDS - started)) -lt 5 ] && ok "a slow pre-scale does not hold the compile's output open" || fail "slow pre-scale held output for $((SECONDS - started)) s"

rm -rf "$WORK/bucket"; run_script PRESCALE_DELAY_SECONDS=1; rc=$?
[ $rc = 0 ] && ! prescaled && ok "a compile that ends before the delay cancels the pre-scale" || fail "pre-scale ran after the compile ended"

rm -rf "$WORK/bucket"; : > "$WORK/calls"; started=$SECONDS
PATH="$WORK/bin:$PATH" CALLS="$WORK/calls" BUCKET_DIR="$WORK/bucket" ANNOTATIONS="$WORK/annotations" \
  BUILDKITE_BRANCH=main BUILDKITE_PARALLEL_JOB=1 BUILDKITE_MESSAGE="Change something" \
  PRESCALE_SCRIPT="$WORK/prescale" PRESCALE_DELAY_SECONDS=8 bash "$SCRIPT" 2>&1 | cat > "$WORK/out"
[ $((SECONDS - started)) -lt 5 ] && ok "a cancelled pre-scale does not hold the job's output open" || fail "output held open for $((SECONDS - started)) s"

rm -rf "$WORK/bucket"; printf '#!/bin/bash\necho "make $*" >> "$CALLS"\nexit 2\n' > "$WORK/bin/make"
run_script PRESCALE_DELAY_SECONDS=1; rc=$?
[ $rc != 0 ] && ! prescaled && ok "a failed compile cancels the pre-scale" || fail "failed compile (rc=$rc)"
printf '#!/bin/bash\necho "make $*" >> "$CALLS"\nsleep "${MAKE_SECONDS:-0}"\n' > "$WORK/bin/make"

seed_cache; run_script BUILDKITE_BRANCH=comp-assets-test PRESCALE_DELAY_SECONDS=0 MAKE_SECONDS=2; rc=$?
[ $rc = 0 ] && ! grep -q "Pre-scaling" "$WORK/out" && ! prescaled && ok "only main pre-scales the production web clusters" || fail "comp-assets branch pre-scaled (rc=$rc)"

echo
echo "PASSED=$PASS FAILED=$FAIL"
[ "$FAIL" = 0 ]
