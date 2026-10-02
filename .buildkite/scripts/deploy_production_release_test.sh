#!/bin/bash
# Harness for the release step at the end of .buildkite/scripts/deploy_production.sh: a deploy
# the spacing gate skipped must not create a GitHub release. CI only `bash -n`s that script, so
# this is the only test of the step. It drives the SHIPPED code, extracted with awk.
#
# The bin/deploy stub writes the skip marker the way gumroad-private's deploy_spacing.sh does:
# at nomad/production/.deploy_spacing_skipped, with content "<DEPLOY_TAG> <build number>", where
# DEPLOY_TAG is the wizard's "production-<first 12 chars of the commit>".
#
# Usage: ./deploy_production_release_test.sh            run the cases
#        ./deploy_production_release_test.sh --mutate   also prove each case FAILS against broken
#                                                       variants of the real script
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/deploy_production.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

COMMIT=649542321aaaabbbbccccddddeeeeffff0000111
BUILD=25000
DEPLOY_TAG="production-${COMMIT:0:12}"

# --- extract the shipped code, no retyping ---
extract() {
  { awk '/^logger\(\) \{/,/^\}/' "$SCRIPT"
    awk '/^announce_skip\(\) \{/,/^\}/' "$SCRIPT"
    awk '/^deploy_skipped_by_spacing_gate\(\) \{/,/^\}/' "$SCRIPT"
    grep -E '^(WEB_REPO|WEB_TAG|PRODUCTION_TAG)=' "$SCRIPT"
  } > "$WORK/fn.sh"
  awk '/^# Deploy to production$/,0' "$SCRIPT" > "$WORK/tail.sh"
  [ -s "$WORK/tail.sh" ] || { echo "FATAL: extraction failed"; exit 1; }
}

# --- a fake checkout root: bin/deploy, the release script, nomad/production ---
APP="$WORK/app"
mkdir -p "$APP/bin" "$APP/.buildkite/scripts" "$APP/nomad/production" "$WORK/stubs"
cat > "$APP/bin/deploy" <<'STUB'
#!/bin/bash
# MARKER_CONTENT unset = the gate let the deploy through; set = the gate skipped and wrote it.
[ "${DEPLOY_FAILS:-}" = "1" ] && exit 1
[ -n "${MARKER_CONTENT+x}" ] && printf '%s' "$MARKER_CONTENT" > "${MARKER_PATH:-nomad/production/.deploy_spacing_skipped}"
exit 0
STUB
printf '#!/bin/bash\necho RELEASE_CREATED\n' > "$APP/.buildkite/scripts/create_github_release.sh"
cat > "$WORK/stubs/buildkite-agent" <<'STUB'
#!/bin/bash
echo "$*" >> "$ANNOTATIONS"
STUB
chmod +x "$APP/bin/deploy" "$WORK/stubs/buildkite-agent"

# Run the release step once -> prints RELEASE, SKIP, or FAILED.
# Extra env assignments (MARKER_CONTENT=..., DEPLOY_FAILS=1, ...) are passed through.
run_case() {
  rm -f "$APP/nomad/production/.deploy_spacing_skipped" "$WORK/annotations" "$WORK/custom_marker"
  (
    cd "$APP" || exit 1
    env BUILDKITE_COMMIT="$COMMIT" BUILDKITE_BUILD_NUMBER="$BUILD" ANNOTATIONS="$WORK/annotations" \
      PATH="$WORK/stubs:$PATH" "$@" \
      bash -c "set -e; source '$WORK/fn.sh'; source '$WORK/tail.sh'"
  ) > "$WORK/out" 2>&1
  local status=$?
  if [ "$status" -ne 0 ]; then echo FAILED
  elif grep -q RELEASE_CREATED "$WORK/out"; then echo RELEASE
  else echo SKIP; fi
}

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); [ -n "${QUIET:-}" ] || echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

check() { # <desc> <expected> [env assignments...]
  local desc="$1" exp="$2"; shift 2
  local got; got=$(run_case "$@")
  if [ "$got" = "$exp" ]; then pass "$desc -> $got"; else fail "$desc -> got $got, expected $exp"; fi
}

cases() {
  check "no marker: the deploy shipped, release created"           RELEASE
  check "marker for this run: no release"                          SKIP    MARKER_CONTENT="$DEPLOY_TAG $BUILD"
  check "marker from an earlier build: stale, release created"     RELEASE MARKER_CONTENT="$DEPLOY_TAG 24999"
  check "marker for another revision: stale, release created"      RELEASE MARKER_CONTENT="production-000000000000 $BUILD"
  check "empty marker: stale, release created"                     RELEASE MARKER_CONTENT=""
  check "DEPLOY_SPACING_SKIP_MARKER override is honoured"          SKIP    MARKER_CONTENT="$DEPLOY_TAG $BUILD" \
    MARKER_PATH="$WORK/custom_marker" DEPLOY_SPACING_SKIP_MARKER="$WORK/custom_marker"
  check "failed deploy: no release"                                FAILED  DEPLOY_FAILS=1

  # The skip exits 0 by design, so the annotation and the log line are its only trace.
  run_case MARKER_CONTENT="$DEPLOY_TAG $BUILD" >/dev/null
  if grep -q -- "--context deploy-skip-Deploy-spacing" "$WORK/annotations" 2>/dev/null; then pass "skip annotates the build"
  else fail "skip annotates the build -> no deploy-skip-Deploy-spacing annotation"; fi
  if grep -qF "commit $COMMIT was NOT published" "$WORK/out"; then pass "skip logs that the commit was not published"
  else fail "skip logs that the commit was not published"; fi
}

extract
echo "=== release step cases ==="
cases
echo
echo "PASS=$PASS FAIL=$FAIL"
BASE_FAIL=$FAIL

# ---------------------------------------------------------------------------
# Mutation testing: each mutation below MUST make the suite fail.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--mutate" ]; then
  echo
  echo "=== mutation testing (each mutant MUST be caught) ==="
  mutate() { # <desc> <perl-expr>
    local desc="$1" expr="$2"
    cp "$SCRIPT" "$WORK/orig.sh"
    perl -0pi -e "$expr" "$SCRIPT"
    if diff -q "$WORK/orig.sh" "$SCRIPT" >/dev/null; then
      echo "SKIP (mutation did not apply): $desc"; cp "$WORK/orig.sh" "$SCRIPT"; return
    fi
    extract
    PASS=0; FAIL=0; QUIET=1 cases
    if [ "$FAIL" -gt 0 ]; then echo "CAUGHT ($FAIL failing): $desc"
    else echo "ESCAPED -- suite is vacuous for: $desc"; ESCAPES=$((ESCAPES+1)); fi
    cp "$WORK/orig.sh" "$SCRIPT"
    extract
  }
  ESCAPES=0
  mutate "no skip check after bin/deploy (the original bug)" \
    's/\nif deploy_skipped_by_spacing_gate; then\n.*?\nfi\n//s'
  mutate "marker presence alone counts as a skip" \
    's/\[ -f "\$marker" \] && \[ .*? \]$/[ -f "\$marker" ]/m'
  mutate "content check ignores the build number" \
    's/\[ "\$\(cat "\$marker" 2>\/dev\/null\)" = "\$PRODUCTION_TAG \$\{BUILDKITE_BUILD_NUMBER:-\}" \]/[[ "\$(cat "\$marker")" == "\$PRODUCTION_TAG "* ]]/'
  mutate "marker looked up at the gate's relative default (checkout root)" \
    's/:-nomad\/production\/\.deploy_spacing_skipped/:-.deploy_spacing_skipped/'
  mutate "DEPLOY_SPACING_SKIP_MARKER override ignored" \
    's/\$\{DEPLOY_SPACING_SKIP_MARKER:-(nomad\/production\/\.deploy_spacing_skipped)\}/$1/'
  mutate "skip logs and annotates but still creates the release" \
    's/(announce_skip "Deploy spacing" "[^"]*")/($1) || true/'
  echo
  echo "MUTANTS_ESCAPED=$ESCAPES"
  [ "$ESCAPES" -eq 0 ] && [ "$BASE_FAIL" -eq 0 ] && echo "ALL GREEN: cases pass, every mutant caught"
fi

[ "$BASE_FAIL" -eq 0 ] || exit 1
