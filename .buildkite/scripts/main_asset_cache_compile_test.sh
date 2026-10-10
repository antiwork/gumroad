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
[ -s "${NODE_MODULES_CACHE_DIR:-/nonexistent}/node_modules.tar.gz" ] && echo "node-modules-restored $(cat "$NODE_MODULES_CACHE_DIR/node_modules.tar.gz")" >> "$CALLS"
[ "${MAKE_WRITES_NODE_MODULES:-}" = 1 ] && echo installed > "$NODE_MODULES_CACHE_DIR/node_modules.tar.gz.new"
[ -s "${PAGES_TAILWIND_CACHE_DIR:-/nonexistent}/pages_tailwind.tar.gz" ] && echo "pages-restored $(cat "$PAGES_TAILWIND_CACHE_DIR/pages_tailwind.tar.gz")" >> "$CALLS"
[ "${MAKE_WRITES_PAGES:-}" = 1 ] && echo built > "$PAGES_TAILWIND_CACHE_DIR/pages_tailwind.tar.gz.new"
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

NM_TAG=$(bash -c 'source .buildkite/scripts/preview_asset_cache.sh; source .buildkite/scripts/main_node_modules_cache.sh; main_node_modules_cache_tag')
NM_ENTRY="$WORK/bucket/buildkite-branch-cache/main-node-modules/$NM_TAG.tar.gz"
seed_node_modules() {
  mkdir -p "$(dirname "$NM_ENTRY")"
  echo cached > "$NM_ENTRY"
  sha256sum "$NM_ENTRY" | cut -d " " -f1 > "$NM_ENTRY.sha256"
}

rm -rf "$WORK/bucket"; seed_node_modules; run_script; rc=$?
[ $rc = 0 ] && compiled && grep -q "^node-modules-restored cached" "$WORK/calls" \
  && ok "a full compile gets the cached node_modules tarball when its checksum matches" || fail "node_modules hit (rc=$rc): $(cat "$WORK/calls")"
[ ! -e .main-node-modules-cache ] && ok "the node_modules cache directory is removed after the compile" || fail "node_modules cache directory left behind"

rm -rf "$WORK/bucket"; seed_node_modules; echo junk >> "$NM_ENTRY"; run_script; rc=$?
[ $rc = 0 ] && compiled && ! grep -q "^node-modules-restored" "$WORK/calls" \
  && ok "a node_modules tarball that fails its checksum is not used" || fail "node_modules bad checksum (rc=$rc)"

rm -rf "$WORK/bucket"; seed_node_modules; run_script BUILDKITE_MESSAGE="Fix a thing [no-cache]" MAKE_WRITES_NODE_MODULES=1; rc=$?
[ $rc = 0 ] && compiled && ! grep -q "^node-modules-restored" "$WORK/calls" && [ "$(cat "$NM_ENTRY")" = installed ] \
  && ok "a no-cache commit installs node_modules and replaces the entry" || fail "node_modules no-cache (rc=$rc)"

rm -rf "$WORK/bucket"; run_script MAKE_WRITES_NODE_MODULES=1; rc=$?
[ $rc = 0 ] && [ "$(cat "$NM_ENTRY" 2>/dev/null)" = installed ] && [ "$(cat "$NM_ENTRY.sha256" 2>/dev/null)" = "$(echo installed | sha256sum | cut -d " " -f1)" ] \
  && ok "main saves the node_modules a full install wrote, with its checksum" || fail "node_modules save on main (rc=$rc): $(ls -R "$WORK/bucket" 2>&1 | tail -3)"

rm -rf "$WORK/bucket"; run_script MAKE_WRITES_NODE_MODULES=1 BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && [ ! -e "$NM_ENTRY" ] && ok "a comp-assets build never writes the node_modules cache" || fail "comp-assets wrote node_modules (rc=$rc)"

PT_TAG=$(bash -c 'source .buildkite/scripts/preview_asset_cache.sh; source .buildkite/scripts/main_pages_tailwind_cache.sh; main_pages_tailwind_cache_tag')
PT_ENTRY="$WORK/bucket/buildkite-branch-cache/main-pages-tailwind/$PT_TAG.tar.gz"
seed_pages() {
  mkdir -p "$(dirname "$PT_ENTRY")"
  echo cached > "$PT_ENTRY"
  sha256sum "$PT_ENTRY" | cut -d " " -f1 > "$PT_ENTRY.sha256"
}

rm -rf "$WORK/bucket"; seed_pages; run_script; rc=$?
[ $rc = 0 ] && compiled && grep -q "^pages-restored cached" "$WORK/calls" && ! grep -q "^node-modules-restored" "$WORK/calls" \
  && ok "a full compile gets the cached pages CSS tarball when its checksum matches" || fail "pages hit (rc=$rc): $(cat "$WORK/calls")"
[ ! -e .main-pages-tailwind-cache ] && ok "the pages CSS cache directory is removed after the compile" || fail "pages cache directory left behind"

rm -rf "$WORK/bucket"; seed_pages; echo junk >> "$PT_ENTRY"; run_script; rc=$?
[ $rc = 0 ] && compiled && ! grep -q "^pages-restored" "$WORK/calls" \
  && ok "a pages CSS tarball that fails its checksum is not used" || fail "pages bad checksum (rc=$rc)"

rm -rf "$WORK/bucket"; seed_pages; run_script BUILDKITE_MESSAGE="Fix a thing [no-cache]" MAKE_WRITES_PAGES=1; rc=$?
[ $rc = 0 ] && compiled && ! grep -q "^pages-restored" "$WORK/calls" && [ "$(cat "$PT_ENTRY")" = built ] \
  && ok "a no-cache commit builds the pages CSS and replaces the entry" || fail "pages no-cache (rc=$rc)"

rm -rf "$WORK/bucket"; run_script MAKE_WRITES_PAGES=1; rc=$?
[ $rc = 0 ] && [ "$(cat "$PT_ENTRY" 2>/dev/null)" = built ] && [ "$(cat "$PT_ENTRY.sha256" 2>/dev/null)" = "$(echo built | sha256sum | cut -d " " -f1)" ] \
  && ok "main saves the pages CSS a full build wrote, with its checksum" || fail "pages save on main (rc=$rc): $(ls -R "$WORK/bucket" 2>&1 | tail -3)"

rm -rf "$WORK/bucket"; run_script MAKE_WRITES_PAGES=1 BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && [ ! -e "$PT_ENTRY" ] && ok "a comp-assets build never writes the pages CSS cache" || fail "comp-assets wrote the pages CSS (rc=$rc)"

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
[ $rc != 0 ] && [ ! -e .main-node-modules-cache ] && ok "a failed compile still removes the node_modules cache directory" \
  || { fail "failed compile left the node_modules cache directory (rc=$rc)"; rm -rf .main-node-modules-cache; }
[ $rc != 0 ] && [ ! -e .main-pages-tailwind-cache ] && ok "a failed compile still removes the pages CSS cache directory" \
  || { fail "failed compile left the pages CSS cache directory (rc=$rc)"; rm -rf .main-pages-tailwind-cache; }
printf '#!/bin/bash\necho "make $*" >> "$CALLS"\nsleep "${MAKE_SECONDS:-0}"\n' > "$WORK/bin/make"

seed_cache; run_script BUILDKITE_BRANCH=comp-assets-test PRESCALE_DELAY_SECONDS=0 MAKE_SECONDS=2; rc=$?
[ $rc = 0 ] && ! grep -q "Pre-scaling" "$WORK/out" && ! prescaled && ok "only main pre-scales the production web clusters" || fail "comp-assets branch pre-scaled (rc=$rc)"

echo
echo "node_modules cache key"

KEY_REPO="$WORK/key-repo"
KEY_SCRIPTS=$PWD/.buildkite/scripts
mkdir -p "$KEY_REPO/docker/web" "$KEY_REPO/spec"
echo '{}' > "$KEY_REPO/package.json"; echo '{}' > "$KEY_REPO/package-lock.json"
echo 'npm ci' > "$KEY_REPO/docker/web/compile_assets.sh"; echo a > "$KEY_REPO/spec/a_spec.rb"
key_commit() { git -C "$KEY_REPO" add -A && git -C "$KEY_REPO" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false commit -q -m "$1"; }
key_tag() { (cd "$KEY_REPO" && bash -c "source $KEY_SCRIPTS/preview_asset_cache.sh; source $KEY_SCRIPTS/main_node_modules_cache.sh; main_node_modules_cache_tag"); }
git -C "$KEY_REPO" init -q && key_commit base; KEY_BASE=$(key_tag)
echo b > "$KEY_REPO/spec/a_spec.rb"; key_commit unrelated
[ "$(key_tag)" = "$KEY_BASE" ] && ok "a change outside the install inputs keeps the key" || fail "unrelated change moved the key"
echo 'npm ci --ignore-scripts' > "$KEY_REPO/docker/web/compile_assets.sh"; key_commit install
[ "$(key_tag)" != "$KEY_BASE" ] && ok "a change to compile_assets.sh changes the key" || fail "compile_assets.sh is not in the key"

echo
echo "pages CSS cache key"

pt_key_tag() { (cd "$KEY_REPO" && bash -c "source $KEY_SCRIPTS/preview_asset_cache.sh; source $KEY_SCRIPTS/main_pages_tailwind_cache.sh; main_pages_tailwind_cache_tag"); }
mkdir -p "$KEY_REPO/scripts" "$KEY_REPO/app/javascript/stylesheets" "$KEY_REPO/lib/tasks"
echo a > "$KEY_REPO/scripts/build_pages_tailwind.mjs"; echo a > "$KEY_REPO/app/javascript/stylesheets/pages_tailwind.css"
echo a > "$KEY_REPO/lib/tasks/pages_tailwind.rake"; key_commit pages; PT_KEY=$(pt_key_tag)
echo c > "$KEY_REPO/spec/a_spec.rb"; key_commit unrelated-pages
[ "$(pt_key_tag)" = "$PT_KEY" ] && ok "a change outside the pages CSS inputs keeps the key" || fail "unrelated change moved the pages CSS key"
for input in scripts/build_pages_tailwind.mjs app/javascript/stylesheets/pages_tailwind.css package-lock.json lib/tasks/pages_tailwind.rake; do
  echo "changed" >> "$KEY_REPO/$input"; key_commit "$input"
  [ "$(pt_key_tag)" != "$PT_KEY" ] && ok "a change to $input changes the pages CSS key" || fail "$input is not in the pages CSS key"
  PT_KEY=$(pt_key_tag)
done

echo
echo "compile_assets.sh in the container, through make build_production"

# Real `make build_production` runs the real docker/web/compile_assets.sh. DOCKER_CMD
# is this stub, which applies the -e and -v flags make passes and runs make's command
# in a sandbox root: the script's /node-modules-cache, /pages-tailwind-cache, /app and
# ~ paths are rewritten into it, and it stops unless make mounts the caches at those paths.
CT="$WORK/container"
mkdir -p "$WORK/ctbin"
cat > "$WORK/ctbin/docker" <<'STUB'
#!/bin/bash
case "$1" in
  ps) [ "$(cat "$CT/run_rc" 2>/dev/null)" = 0 ] && echo container-id ;;
  commit) echo "commit $*" >> "$CALLS" ;;
  run)
    shift; envs=(); mounts=()
    while [ $# -gt 0 ]; do
      case "$1" in
        -e) envs+=("$2"); shift 2 ;;
        -v) mounts+=("$2"); shift 2 ;;
        --name|--network|--label) shift 2 ;;
        --*) shift ;;
        *) break ;;
      esac
    done
    shift # the image
    for mount in "${mounts[@]}"; do
      case "${mount#*:}" in
        /node-modules-cache|/pages-tailwind-cache) ;;
        *) echo "make mounts a cache at ${mount#*:}" >&2; exit 97 ;;
      esac
      ln -s "${mount%%:*}" "$CT${mount#*:}"
      echo "mount $mount" >> "$CALLS"
    done
    mkdir -p "$CT/app/docker/web"
    sed -e "s#/node-modules-cache#$CT/node-modules-cache#g" -e "s#/pages-tailwind-cache#$CT/pages-tailwind-cache#g" -e "s#/app/#$CT/app/#g" \
      -e "s#/tmp/node-compile-cache#$CT/tmp/node-compile-cache#g" "$REAL_COMPILE_ASSETS" > "$CT/app/docker/web/compile_assets.sh"
    chmod +x "$CT/app/docker/web/compile_assets.sh"
    cd "$CT/app" || exit 1
    PATH="$WORK/ctbin:$PATH" env "${envs[@]}" APP_DIR="$CT/app" HOME="$CT/home" "$@"
    rc=$?
    echo $rc > "$CT/run_rc"
    exit $rc ;;
esac
STUB
cat > "$WORK/ctbin/gosu" <<'STUB'
#!/bin/bash
shift
exec "$@"
STUB
cat > "$WORK/ctbin/npm" <<'STUB'
#!/bin/bash
echo "npm $* NODE_ENV=${NODE_ENV:-}" >> "$CALLS"
mkdir -p node_modules && echo installed > node_modules/.marker
STUB
# assets:precompile builds the pages CSS unless the restore set PAGES_TAILWIND_RESTORED
# (lib/tasks/pages_tailwind.rake), so this writes the files only in that case.
cat > "$WORK/ctbin/bundle" <<'STUB'
#!/bin/bash
if [ "${PAGES_TAILWIND_RESTORED:-}" != true ]; then
  mkdir -p public/assets/pages app/javascript/stylesheets
  for f in public/pages-tailwind.css public/pages-tailwind-manifest.json public/assets/pages/pages-tailwind-0.css app/javascript/stylesheets/pages_tailwind.generated.html; do echo built > "$f"; done
fi
echo "bundle $* node_modules=$(cat node_modules/.marker 2>/dev/null) pages=$(cat public/pages-tailwind.css 2>/dev/null)" >> "$CALLS"
STUB
# Fails the archive write, leaving a partial file behind, when TAR_FAIL=1.
cat > "$WORK/ctbin/tar" <<'STUB'
#!/bin/bash
if [ "${TAR_FAIL:-}" = 1 ] && [ "$1" = -cf ]; then echo partial; exit 1; fi
if [ "${PAGES_TAR_FAIL:-}" = 1 ] && [ "$1" = -czf ]; then echo partial > "$2"; exit 1; fi
exec "$REAL_TAR" "$@"
STUB
chmod +x "$WORK/ctbin/"*

# Usage: run_container_build <seed tarball or ""> [make variable overrides...]
run_container_build() {
  seed=$1; shift
  rm -rf "$CT"; mkdir -p "$CT/host-cache" "$CT/home" "$CT/app/nomad/staging/deploy_branch"
  mkdir -p "$CT/host-pages"
  [ -z "$seed" ] || cp "$seed" "$CT/host-cache/node_modules.tar.gz"
  [ -z "${PAGES_SEED_FILE:-}" ] || cp "$PAGES_SEED_FILE" "$CT/host-pages/pages_tailwind.tar.gz"
  echo 'get_app_name() { echo preview; }' > "$CT/app/nomad/staging/deploy_branch/deploy_branch_common.sh"
  : > "$WORK/calls"
  (
    export WORK CT CALLS="$WORK/calls" REAL_COMPILE_ASSETS="$PWD/docker/web/compile_assets.sh" REAL_TAR
    REAL_TAR=$(command -v tar)
    make build_production DOCKER_CMD="$WORK/ctbin/docker" DOCKER_COMPOSE_CMD=true NEW_WEB_TAG=0123456789ab \
      BUILDKITE_BRANCH=main NODE_MODULES_CACHE_DIR="$CT/host-cache" PAGES_TAILWIND_CACHE_DIR="$CT/host-pages" "$@"
  ) > "$WORK/out" 2>&1
}
cache_files() { ls -A "$CT/host-cache" | tr '\n' ' '; }
pages_files() { ls -A "$CT/host-pages" | tr '\n' ' '; }

mkdir -p "$WORK/seed/node_modules" && echo cached > "$WORK/seed/node_modules/.marker"
SEED="$WORK/seed.tar.gz"; tar -czf "$SEED" -C "$WORK/seed" node_modules

run_container_build "" NODE_MODULES_CACHE_DIR= PAGES_TAILWIND_CACHE_DIR=; rc=$?
[ $rc = 0 ] && grep -q "^npm ci NODE_ENV=development" "$WORK/calls" && grep -q "^bundle .* pages=built" "$WORK/calls" && ! grep -q "^mount" "$WORK/calls" \
  && [ ! -e "$CT/node-modules-cache" ] && [ ! -e "$CT/pages-tailwind-cache" ] \
  && ok "without cache mounts the install and the pages CSS build run and nothing is written" || fail "no mount (rc=$rc): $(tail -3 "$WORK/out")"

run_container_build "$SEED"; rc=$?
[ $rc = 0 ] && ! grep -q "^npm" "$WORK/calls" && grep -q "^bundle .* node_modules=cached" "$WORK/calls" && grep -q "^mount .*:/node-modules-cache$" "$WORK/calls" \
  && [ "$(cache_files)" = "node_modules.tar.gz " ] \
  && ok "a mounted tarball replaces the install and nothing is written back" || fail "restore (rc=$rc): $(cat "$WORK/calls"; cache_files)"

run_container_build ""; rc=$?
mkdir -p "$WORK/extracted" && rm -rf "$WORK/extracted/node_modules" && tar -xzf "$CT/host-cache/node_modules.tar.gz.new" -C "$WORK/extracted" 2>/dev/null
[ $rc = 0 ] && grep -q "^npm ci NODE_ENV=development" "$WORK/calls" && [ "$(cache_files)" = "node_modules.tar.gz.new " ] \
  && [ "$(cat "$WORK/extracted/node_modules/.marker" 2>/dev/null)" = installed ] \
  && ok "main writes the installed node_modules to the mounted cache as node_modules.tar.gz.new" || fail "write-back (rc=$rc): $(cat "$WORK/calls"; cache_files)"

run_container_build "" BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && grep -q "^npm ci" "$WORK/calls" && [ -z "$(cache_files)" ] \
  && ok "a comp-assets build installs without creating a node_modules.tar.gz.new it cannot save" || fail "comp-assets write-back (rc=$rc): $(cache_files)"

run_container_build "$SEED" BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && ! grep -q "^npm" "$WORK/calls" && grep -q "^bundle .* node_modules=cached" "$WORK/calls" \
  && ok "a comp-assets build still restores the cached tarball" || fail "comp-assets restore (rc=$rc)"

run_container_build "" TAR_FAIL=1; rc=$?
[ $rc = 0 ] && grep -q "Could not write node_modules to the cache directory" "$WORK/out" && [ -z "$(cache_files)" ] \
  && ok "a failed archive write leaves no partial node_modules.tar.gz.new" || fail "partial archive (rc=$rc): $(cache_files)"

mkdir -p "$WORK/pages-seed/public/assets/pages" "$WORK/pages-seed/app/javascript/stylesheets"
for f in public/pages-tailwind.css public/pages-tailwind-manifest.json public/assets/pages/pages-tailwind-1.css app/javascript/stylesheets/pages_tailwind.generated.html; do
  echo cached > "$WORK/pages-seed/$f"
done
PAGES_SEED="$WORK/pages-seed.tar.gz"
tar -czf "$PAGES_SEED" -C "$WORK/pages-seed" public/pages-tailwind.css public/pages-tailwind-manifest.json public/assets/pages app/javascript/stylesheets/pages_tailwind.generated.html

PAGES_SEED_FILE=$PAGES_SEED run_container_build "$SEED"; rc=$?
[ $rc = 0 ] && grep -q "^bundle .* pages=cached" "$WORK/calls" && grep -q "^mount .*:/pages-tailwind-cache$" "$WORK/calls" \
  && [ "$(cat "$CT/app/public/assets/pages/pages-tailwind-1.css" 2>/dev/null)" = cached ] \
  && [ "$(cat "$CT/app/app/javascript/stylesheets/pages_tailwind.generated.html" 2>/dev/null)" = cached ] \
  && [ "$(pages_files)" = "pages_tailwind.tar.gz " ] \
  && ok "a mounted pages CSS tarball is unpacked before assets:precompile, which skips the build, and nothing is written back" \
  || fail "pages restore (rc=$rc): $(cat "$WORK/calls"; pages_files)"

run_container_build "$SEED"; rc=$?
mkdir -p "$WORK/pages-extracted" && rm -rf "${WORK:?}/pages-extracted/"* && tar -xzf "$CT/host-pages/pages_tailwind.tar.gz.new" -C "$WORK/pages-extracted" 2>/dev/null
[ $rc = 0 ] && grep -q "^bundle .* pages=built" "$WORK/calls" && [ "$(pages_files)" = "pages_tailwind.tar.gz.new " ] \
  && [ "$(cat "$WORK/pages-extracted/public/pages-tailwind.css" 2>/dev/null)" = built ] \
  && [ "$(cat "$WORK/pages-extracted/public/pages-tailwind-manifest.json" 2>/dev/null)" = built ] \
  && [ "$(cat "$WORK/pages-extracted/public/assets/pages/pages-tailwind-0.css" 2>/dev/null)" = built ] \
  && [ "$(cat "$WORK/pages-extracted/app/javascript/stylesheets/pages_tailwind.generated.html" 2>/dev/null)" = built ] \
  && ok "main writes the four pages CSS outputs to the mounted cache as pages_tailwind.tar.gz.new" || fail "pages write-back (rc=$rc): $(cat "$WORK/calls"; pages_files)"

run_container_build "$SEED" BUILDKITE_BRANCH=comp-assets-test; rc=$?
[ $rc = 0 ] && grep -q "^bundle .* pages=built" "$WORK/calls" && [ -z "$(pages_files)" ] \
  && ok "a comp-assets build builds the pages CSS without creating an archive it cannot save" || fail "pages comp-assets (rc=$rc): $(pages_files)"

run_container_build "$SEED" PAGES_TAR_FAIL=1; rc=$?
[ $rc = 0 ] && grep -q "Could not write the pages CSS to the cache directory" "$WORK/out" && [ -z "$(pages_files)" ] \
  && ok "a failed pages CSS archive write leaves no partial file and does not fail the compile" || fail "pages partial archive (rc=$rc): $(pages_files)"

echo
echo "PASSED=$PASS FAILED=$FAIL"
[ "$FAIL" = 0 ]
