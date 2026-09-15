#!/bin/bash
# Harness for .buildkite/scripts/deploy_relevance.sh
#
# CI only ever `bash -n`s the deploy scripts, so this is the only test the no-op
# skip has. It builds a throwaway git repo with a release tag, then drives the
# SHIPPED functions against real commits — no retyped logic.
#
# Usage: ./deploy_relevance_test.sh            run the cases
#        ./deploy_relevance_test.sh --mutate   also prove the cases FAIL against broken
#                                              variants of the library (anti-vacuity)
set -uo pipefail

LIB="$(cd "$(dirname "$0")" && pwd)/deploy_relevance.sh"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }

# --- fixture: a bare "origin" + a clone with one released commit ---------------
make_fixture() {
  rm -rf "$WORK/origin.git" "$WORK/repo"
  git init -q --bare "$WORK/origin.git"
  git clone -q "$WORK/origin.git" "$WORK/repo" 2>/dev/null
  (
    cd "$WORK/repo" || exit 1
    git config user.email t@t; git config user.name t
    mkdir -p app/models spec/models .github/workflows db/migrate app/javascript/x docs
    echo 'class Link; end' > app/models/link.rb
    echo 'describe Link' > spec/models/link_spec.rb
    echo 'on: push' > .github/workflows/tests.yml
    echo '# readme' > README.md
    git add -A && git commit -q -m released
    git tag v2026.09.15.1
    git push -q origin HEAD:main --tags
  )
}

# Back to the released commit, so a case is judged on its own diff and not on
# an unreleased predecessor's (the baseline is the release, so those accumulate).
reset_to_release() { (cd "$WORK/repo" && git checkout -q main && git reset -q --hard v2026.09.15.1); }

# commit <message> <path>=<content>...  -> prints new sha
commit() {
  local msg="$1"; shift
  (
    cd "$WORK/repo" || exit 1
    for kv in "$@"; do
      local path="${kv%%=*}" content="${kv#*=}"
      mkdir -p "$(dirname "$path")"
      if [ "$content" = "@DELETE" ]; then git rm -q "$path"; else echo "$content" > "$path"; git add "$path"; fi
    done
    git commit -q -m "$msg" --allow-empty
    git rev-parse HEAD
  )
}

# Run the shipped decision for a commit -> prints SKIP or DEPLOY (+ captures log)
decide() {
  local sha="$1"; shift
  (
    cd "$WORK/repo" || exit 1
    export BUILDKITE_BRANCH=main BUILDKITE_COMMIT="$sha"
    unset FORCE_DEPLOY
    for kv in "$@"; do export "$kv"; done
    # shellcheck disable=SC1090
    source "$LIB_UNDER_TEST"
    if production_deploy_is_noop > "$WORK/last.log"; then echo SKIP; else echo DEPLOY; fi
  )
}

# The step wrapper must exit 0 on skip and return (continue) on deploy, even
# under `set -e`.
wrapper_outcome() {
  local sha="$1"
  (
    cd "$WORK/repo" || exit 1
    export BUILDKITE_BRANCH="${2:-main}" BUILDKITE_COMMIT="$sha"
    unset FORCE_DEPLOY
    set -e
    # shellcheck disable=SC1090
    source "$LIB_UNDER_TEST"
    skip_if_production_noop "test" >/dev/null
    echo CONTINUED
  ) 2>/dev/null
  local rc=$?
  echo "EXIT $rc"
}

expect() { # <label> <want> <got>
  if [ "$2" = "$3" ]; then ok "$1 -> ${3//$'\n'/ }"; else fail "$1: want $2 got $3 ($(tail -1 "$WORK/last.log" 2>/dev/null))"; fi
}

run_suite() {
  PASS=0; FAIL=0
  make_fixture
  local released; released=$(cd "$WORK/repo" && git rev-parse HEAD)

  local s
  s=$(commit "spec only" "spec/models/link_spec.rb=describe Link do end")
  expect "spec-only commit"                  SKIP   "$(decide "$s")"
  s=$(commit "workflow" ".github/workflows/tests.yml=on: pull_request")
  expect "workflow-only on top of spec-only" SKIP   "$(decide "$s")"
  s=$(commit "root md" "README.md=# new" "CONTRIBUTING.md=hi")
  expect "root markdown"                     SKIP   "$(decide "$s")"
  s=$(commit "pipeline" ".buildkite/pipeline.yml=steps: []" ".buildkite/scripts/x.sh=echo")
  expect "buildkite config"                  SKIP   "$(decide "$s")"
  s=$(commit "frontend test" "app/javascript/x/Foo.test.tsx=test()" "app/javascript/x/__tests__/bar.ts=t")
  expect "frontend unit tests"               SKIP   "$(decide "$s")"
  s=$(commit "spec deleted" "spec/models/link_spec.rb=@DELETE")
  expect "deleted spec"                      SKIP   "$(decide "$s")"

  # Accumulation: a real change followed by a no-op commit must still deploy,
  # because the baseline is the last RELEASE, not the parent commit.
  s=$(commit "real change" "app/models/link.rb=class Link; def x; end; end")
  expect "app change"                        DEPLOY "$(decide "$s")"
  s=$(commit "doc after real" "docs/thing.md=x")
  expect "doc-only AFTER unreleased app change" DEPLOY "$(decide "$s")"
  grep -q 'ships: app/models/link.rb' "$WORK/last.log" && ok "log names the shipping file" || fail "log should name app/models/link.rb"

  # Things that look like docs but ship. Each judged alone against the release.
  make_fixture
  ships_alone() { # <label> <path>=<content>
    reset_to_release
    local sha; sha=$(commit "$1" "$2")
    expect "$1" DEPLOY "$(decide "$sha")"
  }
  ships_alone "help center erb"             "app/views/help_center/articles/contents/_1-x.html.erb=<p>"
  ships_alone "markdown under app/"         "app/services/guide.md=# guide"
  ships_alone "migration"                   "db/migrate/1_add.rb=class Add"
  ships_alone "public/"                     "public/robots.txt=Disallow:"
  ships_alone "Gemfile.lock"                "Gemfile.lock=rails 8"
  ships_alone "Dockerfile"                  "docker/web/Dockerfile=FROM ruby"
  ships_alone "frontend source (not .test)" "app/javascript/x/Foo.tsx=export const a=1"
  ships_alone "config/"                     "config/routes.rb=Rails.application.routes"
  reset_to_release
  s=$(commit "mixed" "spec/a_spec.rb=x" "config/routes.rb=Rails.application.routes")
  expect "mixed spec + config"               DEPLOY "$(decide "$s")"

  # Ambiguities deploy.
  make_fixture
  s=$(commit "spec only" "spec/models/link_spec.rb=describe Link do end")
  expect "FORCE_DEPLOY=1 overrides skip"     DEPLOY "$(decide "$s" FORCE_DEPLOY=1)"
  expect "re-run of released commit"         DEPLOY "$(decide "$released")"
  reset_to_release
  s=$(commit "empty commit")
  expect "empty commit (no files) deploys"   DEPLOY "$(decide "$s")"
  expect "no BUILDKITE_COMMIT"               DEPLOY "$(decide "")"
  (cd "$WORK/repo" && git tag -d v2026.09.15.1 >/dev/null && git push -q origin :refs/tags/v2026.09.15.1)
  expect "no release tag"                    DEPLOY "$(decide "$s")"
  make_fixture
  # Newest tag on a commit that is NOT an ancestor (a diverged history). The
  # divergence is spec-only so that ONLY the ancestor check can force the deploy.
  (cd "$WORK/repo" && git checkout -q -b other && mkdir -p spec && echo z > spec/z_spec.rb && git add spec/z_spec.rb && git commit -q -m other && git tag v2026.09.15.2 && git push -q origin --tags && git checkout -q main)
  s=$(commit "spec only" "spec/models/link_spec.rb=describe Link do end")
  expect "release tag not an ancestor"       DEPLOY "$(decide "$s")"

  # Wrapper semantics under set -e.
  make_fixture
  s=$(commit "spec only" "spec/models/link_spec.rb=x")
  expect "wrapper exits 0 on skip"           "EXIT 0"   "$(wrapper_outcome "$s")"
  s=$(commit "real" "app/models/link.rb=y")
  expect "wrapper continues on deploy"       "CONTINUED
EXIT 0"  "$(wrapper_outcome "$s")"
  reset_to_release
  s=$(commit "spec only again" "spec/models/link_spec.rb=z")
  # A branch that isn't main never skips (preview/comp-assets builds).
  expect "wrapper ignores non-main branch"   "CONTINUED
EXIT 0"  "$(wrapper_outcome "$s" feature-x)"

  echo "$PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}

LIB_UNDER_TEST="$LIB"
echo "== deploy_relevance.sh"
run_suite; SUITE_RC=$?

if [ "${1:-}" = "--mutate" ]; then
  echo
  echo "== mutation check: each broken variant must fail at least one case"
  ESCAPED=0
  mutate() { # <name> <sed-expr>
    local name="$1" expr="$2" out
    LIB_UNDER_TEST="$WORK/mutant-$name.sh"
    sed "$expr" "$LIB" > "$LIB_UNDER_TEST"
    if cmp -s "$LIB" "$LIB_UNDER_TEST"; then echo "  ??   $name: sed did not change anything"; ESCAPED=$((ESCAPED + 1)); return; fi
    out=$(run_suite 2>&1)
    if echo "$out" | grep -q ' 0 failed'; then echo "  ESC  $name (all cases still pass)"; ESCAPED=$((ESCAPED + 1)); else echo "  kill $name"; fi
  }
  mutate "baseline-is-parent"      's|git diff --name-only "\$base" "\$commit"|git diff --name-only "$commit^" "$commit"|'
  mutate "spec-not-excluded"       's/|spec\/\*|/|/'
  mutate "app-md-excluded"         's/\*\.md) \[\[ "\$1" != \*\/\* \]\] \&\& return 0; return 1 ;;/*.md) return 0 ;;/'
  mutate "force-ignored"           's/"\${FORCE_DEPLOY:-}" = "1"/"${FORCE_DEPLOY:-}" = "never"/'
  mutate "ancestor-check-dropped"  's/git merge-base --is-ancestor "\$base" "\$commit" 2>\/dev\/null/true/'
  mutate "empty-diff-skips"        '/echo "empty diff from/{n;s/return 1/return 0/;}'
  mutate "relevant-count-ignored"  's/if \[ "\$relevant" -gt 0 \]; then/if [ "$relevant" -gt 999 ]; then/'
  mutate "wrapper-skips-all-branches" 's/\[ "\${BUILDKITE_BRANCH:-}" = "main" \] || return 0/true/'
  mutate "wrapper-set-e-unsafe"    's/decision=\$(production_deploy_is_noop) || rc=\$?/decision=$(production_deploy_is_noop); rc=$?/'
  mutate "js-tests-not-excluded"   's/app\/javascript\/\*\.test\.ts|app\/javascript\/\*\.test\.tsx|app\/javascript\/\*\/__tests__\/\*) return 0 ;;//'
  echo "MUTANTS_ESCAPED=$ESCAPED"
  [ "$ESCAPED" -eq 0 ] || SUITE_RC=1
fi
exit $SUITE_RC
