#!/bin/bash
# `check && ok || fail` is safe here: ok never fails.
# shellcheck disable=SC2015
# Harness for main_asset_cache_shadow.sh: runs the real script against stub
# docker, aws, and buildkite-agent binaries, with a local directory as the S3
# bucket. Run from the repo root: .buildkite/scripts/main_asset_cache_shadow_test.sh
set -uo pipefail

SCRIPT=.buildkite/scripts/main_asset_cache_shadow.sh
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

mkdir -p "$WORK/bin"
# `docker run` prints a tar of $IMAGE_DIR, standing in for the production image.
cat > "$WORK/bin/docker" <<'STUB'
#!/bin/bash
case "$1" in
  pull) exit "${PULL_RC:-0}" ;;
  run) tar -cf - -C "$IMAGE_DIR" . ;;
  *) exit 1 ;;
esac
STUB
# `aws s3 cp` between the local bucket dir and files.
cat > "$WORK/bin/aws" <<'STUB'
#!/bin/bash
[ "$1 $2" = "s3 cp" ] || exit 1
src=$3 dst=$4
to_path() { echo "$BUCKET_DIR/${1#s3://}"; }
case "$src" in
  s3://*) [ -f "$(to_path "$src")" ] || exit 1; cp "$(to_path "$src")" "$dst" ;;
  *) [ "${UPLOAD_FAIL:-}" = 1 ] && exit 1; mkdir -p "$(dirname "$(to_path "$dst")")"; cp "$src" "$(to_path "$dst")" ;;
esac
STUB
cat > "$WORK/bin/buildkite-agent" <<'STUB'
#!/bin/bash
cat >> "$ANNOTATIONS"
STUB
chmod +x "$WORK/bin/"*

# A production image with every cached path.
make_image() {
  local dir=$1 marker=$2 map=${3:-map}
  rm -rf "$dir"
  mkdir -p "$dir/public/vite/assets" "$dir/public/js" "$dir/public/assets/pages" "$dir/app/javascript/utils" "$dir/app/javascript/json_schemas"
  echo "bundle $marker" > "$dir/public/vite/assets/app.js"
  echo "$map" > "$dir/public/vite/assets/app.js.map"
  echo "widget" > "$dir/public/js/widget.js"
  echo "css" > "$dir/public/pages-tailwind.css"
  echo "{}" > "$dir/public/pages-tailwind-manifest.json"
  echo "page" > "$dir/public/assets/pages/a.css"
  echo "routes" > "$dir/app/javascript/utils/routes.js"
  echo "types" > "$dir/app/javascript/utils/routes.d.ts"
  echo "schema" > "$dir/app/javascript/json_schemas/a.ts"
}

run_script() {
  : > "$WORK/annotations"
  PATH="$WORK/bin:$PATH" IMAGE_DIR="$WORK/image" BUCKET_DIR="$WORK/bucket" ANNOTATIONS="$WORK/annotations" \
    BUILDKITE_BRANCH=main FORCE_DEPLOY=1 BUILDKITE_COMMIT=0123456789abcdef ECR_REGISTRY=ecr.example \
    GUM_AWS_ACCESS_KEY_ID=x GUM_AWS_SECRET_ACCESS_KEY=y env "$@" bash "$SCRIPT" > "$WORK/out" 2>&1
}

result_of() { grep -o 'result=[a-z]*' "$WORK/out" | tail -1; }

echo "main_asset_cache_shadow.sh"

rm -rf "$WORK/bucket"
make_image "$WORK/image" one
run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=miss ] && grep -q "saved=true" "$WORK/out" && ok "a first run is a miss and saves" || fail "a first run is a miss and saves (rc=$rc $(result_of))"
ls "$WORK/bucket/buildkite-branch-cache/main-asset-cache/"*.tar.gz.sha256 >/dev/null 2>&1 && ok "it saves under the main prefix with a sidecar" || fail "it saves under the main prefix with a sidecar"
# Under pipefail, `tar | grep -q` fails when grep exits early and tar takes SIGPIPE.
listing=$(tar -tzf "$WORK/bucket/buildkite-branch-cache/main-asset-cache/"*.tar.gz)
grep -q "app/javascript/utils/routes.js" <<<"$listing" && ok "the saved files include routes.js" || fail "the saved files include routes.js"

run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=hit ] && grep -q "files=9 mismatched=0 maps_differing=0" "$WORK/out" && ok "the same files again are a hit" || fail "the same files again are a hit (rc=$rc $(cat "$WORK/out" | tail -1))"
grep -q "result=hit" "$WORK/annotations" && ok "a hit is annotated" || fail "a hit is annotated"

make_image "$WORK/image" two
run_script; rc=$?
[ $rc = 1 ] && [ "$(result_of)" = result=mismatch ] && grep -q "public/vite/assets/app.js" "$WORK/out" && ok "different files are a mismatch that names the file" || fail "different files are a mismatch that names the file (rc=$rc $(result_of))"

make_image "$WORK/image" one other-mappings
run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=hit ] && grep -q "mismatched=0 maps_differing=1" "$WORK/out" && ok "a source map that differs alone is a hit that counts it" || fail "a source map that differs alone is a hit that counts it (rc=$rc $(result_of))"

make_image "$WORK/image" two other-mappings
run_script; rc=$?
[ $rc = 1 ] && [ "$(result_of)" = result=mismatch ] && grep -q "public/vite/assets/app.js;" "$WORK/out" && ! grep -q "app.js.map" "$WORK/out" && ok "a mismatch names the differing JavaScript, not its map" || fail "a mismatch names the differing JavaScript, not its map (rc=$rc $(result_of))"

make_image "$WORK/image" one
rm "$WORK/image/public/vite/assets/app.js.map"
run_script; rc=$?
[ $rc = 1 ] && [ "$(result_of)" = result=mismatch ] && grep -q "app.js.map" "$WORK/out" && ok "a missing source map is a mismatch" || fail "a missing source map is a mismatch (rc=$rc $(result_of))"

make_image "$WORK/image" one
rm "$WORK/image/app/javascript/utils/routes.js"
run_script; rc=$?
[ $rc = 1 ] && [ "$(result_of)" = result=mismatch ] && ok "a missing file is a mismatch" || fail "a missing file is a mismatch (rc=$rc $(result_of))"

rm -rf "$WORK/bucket"; make_image "$WORK/image" one
run_script UPLOAD_FAIL=1; rc=$?
[ $rc = 0 ] && grep -q "saved=false" "$WORK/out" && ok "a failed upload is reported, not fatal" || fail "a failed upload is reported, not fatal (rc=$rc)"

run_script PULL_RC=1; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=error ] && ok "a failed pull is an error, not fatal" || fail "a failed pull is an error, not fatal (rc=$rc $(result_of))"

rm -rf "$WORK/image"; mkdir -p "$WORK/image"
run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=error ] && [ ! -d "$WORK/bucket/buildkite-branch-cache/main-asset-cache" ] && ok "an image without compiled files saves nothing" || fail "an image without compiled files saves nothing (rc=$rc $(result_of))"

# A corrupt tarball fails its checksum, so restore treats it as a miss.
rm -rf "$WORK/bucket"; make_image "$WORK/image" one
run_script
for f in "$WORK/bucket/buildkite-branch-cache/main-asset-cache/"*.tar.gz; do echo junk >> "$f"; done
run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=miss ] && ok "a tarball that fails its checksum is a miss" || fail "a tarball that fails its checksum is a miss (rc=$rc $(result_of))"

# A cached tarball that verifies but will not extract is an error, not a
# comparison against nothing.
rm -rf "$WORK/bucket"; make_image "$WORK/image" one
run_script
for f in "$WORK/bucket/buildkite-branch-cache/main-asset-cache/"*.tar.gz; do
  echo "not a tarball" > "$f"; sha256sum "$f" | cut -d " " -f1 > "$f.sha256"
done
run_script; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=error ] && ok "a cached tarball that will not extract is an error" || fail "a cached tarball that will not extract is an error (rc=$rc $(result_of))"

# A failed archive uploads nothing.
rm -rf "$WORK/bucket"; make_image "$WORK/image" one
mkdir -p "$WORK/failtar"
cat > "$WORK/failtar/tar" <<'STUB'
#!/bin/bash
[ "$1" = "-czf" ] && exit 1
exec "$REAL_TAR" "$@"
STUB
chmod +x "$WORK/failtar/tar"
run_script PATH="$WORK/failtar:$WORK/bin:$PATH" REAL_TAR="$(command -v tar)"; rc=$?
[ $rc = 0 ] && [ "$(result_of)" = result=error ] && [ ! -d "$WORK/bucket/buildkite-branch-cache/main-asset-cache" ] && ok "a failed archive is an error and uploads nothing" || fail "a failed archive is an error and uploads nothing (rc=$rc $(result_of))"

[ ! -e .main-asset-cache-shadow ] && ok "it leaves no work directory behind" || fail "it leaves no work directory behind"

# A block step waits for every step above it: above the approval gate, the
# shadow step would hold every deploy.
ruby -ryaml -e '
  steps = YAML.load_file(".buildkite/pipeline.yml")["steps"]
  index = ->(key) { steps.index { |step| step["key"] == key } }
  shadow = steps[index.("asset-cache-shadow")]
  deploy = steps[index.("production-deployment")]
  ok = index.("asset-cache-shadow") > index.("require-approval") &&
       shadow["depends_on"] == "compile-assets" && shadow["soft_fail"] == true &&
       !Array(deploy["depends_on"]).include?("asset-cache-shadow")
  exit(ok ? 0 : 1)
' && ok "the shadow step sits below the approval gate, and the deploy does not wait for it" \
  || fail "the shadow step sits below the approval gate, and the deploy does not wait for it"

echo
echo "PASSED=$PASS FAILED=$FAIL"
[ "$FAIL" = 0 ]
