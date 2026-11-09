#!/bin/bash
# Harness for .buildkite/scripts/create_github_release.sh, the last thing deploy_production.sh
# sources and therefore the last thing that can fail its step.
#
# It exists because the step failed on a SHIPPED deploy: builds 28142 and 28143 each lost the gh
# CLI download to a 504 from github.com's release CDN, and under `set -e` that aborted the step
# after `bin/deploy` had already switched production traffic. The commit was marked failed, main
# went red, and every PR cut from main inherited it. So the cases below pin the two decisions
# that came out of it:
#
#   * the tag push stays fatal (deploy_relevance.sh diffs against the tag), and
#   * creating the Release is best effort over two transports -- the gh CLI, then the REST API on
#     api.github.com, a different host from the CDN the CLI download needs -- and when BOTH fail
#     the step still exits 0, with a warning and a Buildkite annotation.
#
# The whole shipped script runs, with gh/git/curl/buildkite-agent doubled on PATH.
#
# Usage: ./create_github_release_test.sh            run the cases
#        ./create_github_release_test.sh --mutate   also prove each case FAILS against broken variants
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RELEASE_SCRIPT="$SCRIPT_DIR/create_github_release.sh"
ENSURE_SCRIPT="$SCRIPT_DIR/ensure_gh.sh"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK" /tmp/gh.tar.gz "/tmp/gh_2.65.0_linux_amd64" /tmp/gh_release_api_response.json' EXIT

COMMIT=649542321aaaabbbbccccddddeeeeffff0000111
TODAY=$(date -u +%Y.%m.%d)
PREV_TAG="v2026.11.08.4"
VERSION_TAG="v${TODAY}.1"

mkdir -p "$WORK/bin" "$WORK/ghbin"

# --- test doubles ---------------------------------------------------------------------------
# git: today has no tag yet (SEQUENCE=1), PREVIOUS_TAGS is the last release, and the push can be
# made to fail. Every call is logged.
cat > "$WORK/bin/git" <<'STUB'
#!/bin/bash
printf 'git %s\n' "$*" >> "$GIT_LOG"
case "$1" in
  fetch) exit 0 ;;
  push) exit "${GIT_PUSH_EXIT:-0}" ;;
  log) printf '%s\n' "${STUB_COMMIT_TITLE:-stub subject}"; exit 0 ;;
  tag)
    if [ "$2" = "-l" ]; then
      case "$3" in
        "v${STUB_TODAY}."*) [ -n "${TODAY_TAGS:-}" ] && printf '%s\n' $TODAY_TAGS ;;
        *) [ -n "${PREVIOUS_TAGS:-}" ] && printf '%s\n' $PREVIOUS_TAGS ;;
      esac
    fi
    exit 0 ;;
esac
exit 0
STUB

# curl answers two different callers: the gh CLI download (recorded, then fails or succeeds) and
# the REST API POST (body saved for inspection, HTTP status chosen by the test).
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
printf 'curl %s\n' "$*" >> "$CURL_LOG"
case "$*" in
  *api.github.com*)
    out=""; prev=""
    for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
    cat > "$API_BODY"
    [ -n "$out" ] && printf '%s' "${API_RESPONSE_TEXT:-{\"id\":1,\"tag_name\":\"stub\"}}" > "$out"
    printf '%s' "${API_HTTP_CODE:-201}"
    exit 0 ;;
esac
exit "${DOWNLOAD_EXIT:-0}"
STUB

cat > "$WORK/bin/buildkite-agent" <<'STUB'
#!/bin/bash
printf '%s\n' "$*" >> "$ANNOTATIONS"
STUB

cat > "$WORK/ghbin/gh" <<'STUB'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$GH_LOG"
exit "${GH_EXIT:-0}"
STUB
chmod +x "$WORK/bin/git" "$WORK/bin/curl" "$WORK/bin/buildkite-agent" "$WORK/ghbin/gh"

# --- one run of the shipped release step ----------------------------------------------------
# Prints the step's exit status. Overrides are passed as KEY=VALUE arguments, defaulted here, and
# `GH_PRESENT` decides whether a gh is on PATH -- not a `VAR=x run_case` prefix, whose temporary
# assignment a later case could inherit and silently skip the download.
run_case() {
  rm -rf "$WORK/app"
  mkdir -p "$WORK/app/.buildkite/scripts"
  cp "$RELEASE_SCRIPT" "$WORK/app/.buildkite/scripts/create_github_release.sh"
  cp "$ENSURE_SCRIPT" "$WORK/app/.buildkite/scripts/ensure_gh.sh"
  : > "$WORK/curl.log"; : > "$WORK/gh.log"; : > "$WORK/git.log"; : > "$WORK/annotations"
  rm -f "$WORK/api_body"
  local path="$WORK/bin:/usr/bin:/bin" gh_present=0 o
  local env_args=(
    BUILDKITE_COMMIT="$COMMIT" BUILDKITE_BUILD_NUMBER=25100
    BUILDKITE_BUILD_URL="https://buildkite.com/gumroad-inc/gumroad/builds/25100"
    GITHUB_TOKEN="stub-token" RELEASE_GITHUB_REPO="antiwork/gumroad"
    CURL_LOG="$WORK/curl.log" GH_LOG="$WORK/gh.log" GIT_LOG="$WORK/git.log"
    ANNOTATIONS="$WORK/annotations" API_BODY="$WORK/api_body" STUB_TODAY="$TODAY"
    TODAY_TAGS="" PREVIOUS_TAGS="$PREV_TAG" STUB_COMMIT_TITLE="stub subject"
    API_HTTP_CODE=201 API_RESPONSE_TEXT="" GH_EXIT=0 GIT_PUSH_EXIT=0 DOWNLOAD_EXIT=0
  )
  for o in "$@"; do
    case "$o" in
      GH_PRESENT=*) gh_present="${o#GH_PRESENT=}"; continue ;;
    esac
    env_args+=("$o")
  done
  [ "$gh_present" = "1" ] && path="$WORK/ghbin:$path"
  (
    cd "$WORK/app" || exit 1
    env PATH="$path" "${env_args[@]}" \
      bash -c 'set -e; source .buildkite/scripts/create_github_release.sh'
  ) > "$WORK/out" 2>&1
  echo "$?"
}

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); [ -n "${QUIET:-}" ] || echo "PASS: $1"; }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }

json_field() { # <field> -> the payload the REST fallback sent
  python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$WORK/api_body" "$1" 2>/dev/null
}
json_valid() {
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$WORK/api_body" 2>/dev/null
}
api_called() { grep -q "api.github.com" "$WORK/curl.log"; }

cases() {
  local st

  # 1. The happy path: gh on PATH and working. The CLI is used, and nothing calls the API.
  st=$(run_case GH_PRESENT=1)
  if [ "$st" = 0 ] && grep -q "created with the gh CLI" "$WORK/out" && ! api_called; then
    pass "gh available and working -> the CLI creates the release, no API call"
  else
    fail "gh available and working -> status $st, api called: $(api_called && echo yes || echo no)"
  fi
  if grep -q -- "release create $VERSION_TAG --target $COMMIT --generate-notes --notes-start-tag $PREV_TAG" "$WORK/gh.log"; then
    pass "the CLI is asked for generated notes since the previous release"
  else
    fail "generated notes -> gh log: $(cat "$WORK/gh.log")"
  fi

  # 2. gh works but its subcommand fails: the REST fallback creates the release, and the step
  #    still exits 0.
  st=$(run_case GH_PRESENT=1 GH_EXIT=1)
  if [ "$st" = 0 ] && grep -q "created over the REST API" "$WORK/out" && api_called; then
    pass "gh release create fails -> the REST API creates the release"
  else
    fail "gh release create fails -> status $st, out: $(grep -c 'created over' "$WORK/out")"
  fi
  if json_valid && [ "$(json_field tag_name)" = "$VERSION_TAG" ] &&
    [ "$(json_field target_commitish)" = "$COMMIT" ] &&
    [ "$(json_field generate_release_notes)" = "True" ] &&
    [ "$(json_field previous_tag_name)" = "$PREV_TAG" ]; then
    pass "the REST body mirrors --generate-notes --notes-start-tag"
  else
    fail "the REST body -> $(cat "$WORK/api_body" 2>/dev/null)"
  fi
  if grep -q -- "Authorization: Bearer stub-token" "$WORK/curl.log" &&
    grep -q -- "X-GitHub-Api-Version" "$WORK/curl.log" &&
    grep -q -- "repos/antiwork/gumroad/releases" "$WORK/curl.log"; then
    pass "the REST call is authenticated and aimed at the repo's releases"
  else
    fail "the REST call -> curl log: $(cat "$WORK/curl.log")"
  fi

  # 3. THE REGRESSION. No gh on PATH (the deploy image has none) and the CDN download fails with
  #    the 504 both builds got. The step must NOT fail: production is already live by then.
  st=$(run_case GH_PRESENT=0 DOWNLOAD_EXIT=22)
  if [ "$st" = 0 ] && grep -q "created over the REST API" "$WORK/out"; then
    pass "CDN download fails (504) -> step exits 0, release created over the REST API"
  else
    fail "CDN download fails -> status $st, out: $(tail -5 "$WORK/out" | tr '\n' ' ')"
  fi
  if grep -q "could not be installed" "$WORK/out"; then
    pass "the failed download is a warning, not an abort"
  else
    fail "the failed download is a warning -> $(grep -c 'could not be installed' "$WORK/out") in the log"
  fi

  # 4. Both transports down and no gh: still exit 0, with a warning and an annotation so the loss
  #    of the release is visible without blocking every PR cut from main.
  st=$(run_case GH_PRESENT=0 DOWNLOAD_EXIT=22 API_HTTP_CODE=500)
  if [ "$st" = 0 ] && grep -q "was NOT created" "$WORK/out"; then
    pass "both transports down -> step exits 0 with a warning"
  else
    fail "both transports down -> status $st, out: $(tail -5 "$WORK/out" | tr '\n' ' ')"
  fi
  if grep -q -- "--style warning --context release-not-created" "$WORK/annotations"; then
    pass "the lost release is annotated on the build"
  else
    fail "the lost release is annotated -> $(cat "$WORK/annotations" 2>/dev/null)"
  fi
  if grep -q "500" "$WORK/out"; then pass "the API's own status is logged"; else fail "the API status is logged"; fi

  # 5. A 422 means the release already exists, which a re-run of the same commit hits: that is
  #    done, not failed.
  st=$(run_case GH_PRESENT=1 GH_EXIT=1 API_HTTP_CODE=422)
  if [ "$st" = 0 ] && grep -q "created over the REST API" "$WORK/out" && ! grep -q "was NOT created" "$WORK/out"; then
    pass "a release that already exists (422) counts as created"
  else
    fail "422 already-exists -> status $st, out: $(grep -c 'was NOT created' "$WORK/out")"
  fi

  # 6. The tag push stays fatal: it is what deploy_relevance.sh reads, so a missing tag must fail
  #    the step rather than be papered over.
  st=$(run_case GH_PRESENT=1 GIT_PUSH_EXIT=1)
  if [ "$st" != 0 ] && ! api_called; then
    pass "a failed tag push still fails the step"
  else
    fail "a failed tag push -> status $st, api called: $(api_called && echo yes || echo no)"
  fi

  # 7. A first release ever: no previous tag, so the notes are the hand-built initial ones and the
  #    REST body must carry them (and stay valid JSON even when the subject has quotes in it).
  st=$(run_case GH_PRESENT=1 PREVIOUS_TAGS= STUB_COMMIT_TITLE='Say "hello" \ goodbye' GH_EXIT=1)
  if [ "$st" = 0 ] && grep -q "created over the REST API" "$WORK/out" && json_valid; then
    pass "first release, subject with quotes -> valid REST body"
  else
    fail "first release, subject with quotes -> status $st, body: $(cat "$WORK/api_body" 2>/dev/null)"
  fi
  if [ -z "$(json_field generate_release_notes)" ] &&
    [ "$(json_field name)" = "$VERSION_TAG" ] &&
    python3 -c 'import json,sys; b=json.load(open(sys.argv[1]))["body"]; sys.exit(0 if b.startswith("Initial release.") and "Say \"hello\" \\ goodbye" in b else 1)' "$WORK/api_body" 2>/dev/null; then
    pass "the initial release keeps its notes, unescaped for the reader"
  else
    fail "the initial release body -> $(cat "$WORK/api_body" 2>/dev/null)"
  fi
}

echo "=== create_github_release cases ==="
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
    cp "$RELEASE_SCRIPT" "$WORK/orig.sh"
    perl -0pi -e "$expr" "$RELEASE_SCRIPT"
    if diff -q "$WORK/orig.sh" "$RELEASE_SCRIPT" >/dev/null; then
      echo "SKIP (mutation did not apply): $desc"; cp "$WORK/orig.sh" "$RELEASE_SCRIPT"; return
    fi
    PASS=0; FAIL=0; QUIET=1 cases
    if [ "$FAIL" -gt 0 ]; then echo "CAUGHT ($FAIL failing): $desc"
    else echo "ESCAPED -- suite is vacuous for: $desc"; ESCAPES=$((ESCAPES+1)); fi
    cp "$WORK/orig.sh" "$RELEASE_SCRIPT"
  }
  ESCAPES=0
  mutate "a failed CLI download aborts the step again (the original bug)" \
    's/^if gh_cli_available; then$/gh_cli_available; if true; then/m'
  mutate "the REST fallback is never tried" \
    's/^  create_release_with_api "\$VERSION_TAG" "\$COMMIT_SHA" "\$PREVIOUS_TAG" "\$COMMIT_TITLE"; then$/  false; then/m'
  mutate "a release nobody could create fails the deploy again" \
    's/^  warn "GitHub Release \$\{VERSION_TAG\} was NOT created.*$/  warn "not created"; exit 1/m'
  mutate "the REST body stops escaping the commit subject" \
    's/\$\(json_escape "\$initial_title"\)/$initial_title/'
  mutate "the REST body stops asking for generated notes" \
    's/"generate_release_notes":true/"generate_release_notes":false/'
  mutate "an already-created release counts as a failure" \
    's/201\|422\)/201)/'
  echo
  echo "MUTANTS_ESCAPED=$ESCAPES"
  [ "$ESCAPES" -eq 0 ] && [ "$BASE_FAIL" -eq 0 ] && echo "ALL GREEN: cases pass, every mutant caught"
fi

[ "$BASE_FAIL" -eq 0 ] || exit 1
