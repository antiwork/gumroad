#!/bin/bash
# Sourced as a library by the main-branch steps (build_base, build_web,
# compile_assets, deploy_production). Does not change the caller's shell options.
#
# Skips the whole production pipeline when nothing that ships has changed.
#
# A main deploy costs ~23 minutes of agent time plus a blue/green rollout of the
# web tier, and a meaningful share of main commits change nothing the running app
# can see: specs, GitHub workflows, docs, editor config, the pipeline itself.
# Deploying those rebuilds and ships a byte-identical application.
#
# Baseline: the commit of the latest release tag (v<YYYY>.<MM>.<DD>.<N>), because
# that tag is created by deploy_production.sh only after `bin/deploy` succeeded —
# it IS what production is running. Comparing against the parent commit would be
# wrong: two consecutive no-op commits would each look clean, but so would a real
# change that was skipped for another reason (a long-running-job skip, a failed
# deploy) and then followed by a doc-only commit. Diffing against the last
# release makes every skipped change accumulate into the next deploy's diff.
#
# Every ambiguity deploys: no tag, tag not an ancestor of this commit (shallow
# clone, rewritten history), git errors, an empty diff (a re-run of an already
# released commit — deploying it is what a re-run asks for), FORCE_DEPLOY=1.
#
# Escape hatch: Buildkite "Rebuild" with env FORCE_DEPLOY=1. Every step honours
# it, which matters — a no-op build has NO production-<sha> image, so re-running
# only the deploy step would fail on `docker manifest inspect`.

# Paths that are never part of the shipped application. Matched with bash
# extglob-free patterns via `case`, so `*` crosses `/`. Keep this list to things
# the Docker build either excludes (.dockerignore) or copies in but nothing in
# app/, config/, lib/, db/ or public/ ever reads at runtime.
deploy_irrelevant_path() {
  case "$1" in
    .github/*|docs/*|spec/*|test/*|qa-media/*) return 0 ;;
    .buildkite/*|ci_scripts/*|.githooks/*) return 0 ;;
    .claude/*|.agents/*|.autoreview/*|.vscode/*) return 0 ;;
    .gitignore|.gitattributes|.git-blame-ignore-revs|.dockerignore) return 0 ;;
    .rubocop.yml|.rspec|.prettierrc|.prettierignore|eslint.config.js|vitest.config.ts) return 0 ;;
    .cursorignore|.claudeignore|.pr_body.md) return 0 ;;
    # Root-level markdown only. app/**/*.md is not excluded on purpose: the
    # help center and the LLM guide render some content from the tree.
    *.md) [[ "$1" != */* ]] && return 0; return 1 ;;
    # Frontend unit tests are never imported by an entrypoint, so Vite does not
    # bundle them.
    app/javascript/*.test.ts|app/javascript/*.test.tsx|app/javascript/*/__tests__/*) return 0 ;;
  esac
  return 1
}

# Prints the release-tag baseline commit, or nothing when there is none.
deploy_relevance_baseline() {
  local tag
  git fetch --quiet --tags --force origin >/dev/null 2>&1 || return 1
  tag=$(git tag -l 'v*.*.*.*' | sort -t. -k1,1 -k2,2n -k3,3n -k4,4n | tail -1)
  [ -n "$tag" ] || return 1
  git rev-parse --verify --quiet "${tag}^{commit}"
}

# Returns 0 when this commit changes nothing that ships relative to the last
# release, 1 when it does (or when that cannot be determined). Prints its
# reasoning on stdout, one line per decision, so the step log explains itself.
production_deploy_is_noop() {
  local commit="${BUILDKITE_COMMIT:-}" base files f relevant=0 total=0

  if [ "${FORCE_DEPLOY:-}" = "1" ]; then
    echo "FORCE_DEPLOY=1 set — deploying regardless of the diff"
    return 1
  fi
  if [ -z "$commit" ]; then
    echo "BUILDKITE_COMMIT is unset — deploying"
    return 1
  fi

  if ! base=$(deploy_relevance_baseline) || [ -z "$base" ]; then
    echo "no release tag found to compare against — deploying"
    return 1
  fi
  if ! git merge-base --is-ancestor "$base" "$commit" 2>/dev/null; then
    echo "last release ${base:0:12} is not an ancestor of ${commit:0:12} — deploying"
    return 1
  fi
  if [ "$base" = "$commit" ]; then
    echo "${commit:0:12} is already the released commit — deploying (re-run)"
    return 1
  fi

  if ! files=$(git diff --name-only "$base" "$commit" 2>/dev/null); then
    echo "git diff ${base:0:12}..${commit:0:12} failed — deploying"
    return 1
  fi
  if [ -z "$files" ]; then
    echo "empty diff from ${base:0:12} to ${commit:0:12} — deploying"
    return 1
  fi

  while IFS= read -r f; do
    [ -n "$f" ] || continue
    total=$((total + 1))
    if ! deploy_irrelevant_path "$f"; then
      relevant=$((relevant + 1))
      [ "$relevant" -le 5 ] && echo "ships: $f"
    fi
  done <<< "$files"

  if [ "$relevant" -gt 0 ]; then
    echo "$relevant of $total changed files since ${base:0:12} ship to production — deploying"
    return 1
  fi
  echo "none of the $total files changed since ${base:0:12} ship to production — nothing to deploy"
  return 0
}

# Call at the top of a main-branch step. Exits 0 (step passes, does nothing)
# when the build is a no-op for production; returns otherwise. Never exits
# non-zero: a broken relevance check must fall through to a normal deploy.
skip_if_production_noop() {
  local step="${1:-step}" decision
  [ "${BUILDKITE_BRANCH:-}" = "main" ] || return 0

  # Callers run under `set -e`; a plain `decision=$(...)` returning 1 would abort
  # the step instead of deploying.
  local rc=0
  decision=$(production_deploy_is_noop) || rc=$?
  printf '%s\n' "$decision" | sed "s/^/${step}: [deploy relevance] /"
  [ "$rc" -eq 0 ] || return 0

  if command -v buildkite-agent >/dev/null 2>&1; then
    printf 'Production deploy skipped: this commit changes nothing that ships (%s). Rebuild with `FORCE_DEPLOY=1` to deploy anyway.\n' \
      "$(printf '%s\n' "$decision" | tail -1)" \
      | buildkite-agent annotate --style info --context "noop-production-deploy" 2>/dev/null || true
  fi
  echo "${step}: skipping — nothing to deploy for ${BUILDKITE_COMMIT:-?}"
  exit 0
}
