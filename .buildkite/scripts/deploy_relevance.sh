#!/bin/bash
# Sourced by the four main-branch steps (build_base, build_web, compile_assets, deploy_production)
# to skip the whole production pipeline when nothing that ships changed. Does not change the
# caller's shell options.

# Paths the Docker build either excludes or copies in but nothing reads at runtime. Matched with
# `case` patterns, so `*` crosses `/`. Build inputs are absent on purpose: .dockerignore and
# .buildkite/ change what the image is built from, and a guard that skips the only run that would
# exercise a pipeline change cannot be observed.
deploy_irrelevant_path() {
  case "$1" in
    .github/*|docs/*|spec/*|test/*|qa-media/*) return 0 ;;
    ci_scripts/*|.githooks/*) return 0 ;;
    .claude/*|.agents/*|.autoreview/*|.vscode/*) return 0 ;;
    .gitignore|.gitattributes|.git-blame-ignore-revs) return 0 ;;
    .rubocop.yml|.rspec|.prettierrc|.prettierignore|eslint.config.js|vitest.config.ts) return 0 ;;
    .cursorignore|.claudeignore|.pr_body.md) return 0 ;;
    # Root-level markdown only: the help center and LLM guide render app/**/*.md from the tree.
    *.md) [[ "$1" != */* ]] && return 0; return 1 ;;
    # Never imported by an entrypoint, so Vite does not bundle them.
    app/javascript/*.test.ts|app/javascript/*.test.tsx|app/javascript/*/__tests__/*) return 0 ;;
  esac
  return 1
}

# The v* tag is created only after `bin/deploy` succeeds, so it IS what production runs. Diffing
# against the parent instead would drop a change that was skipped (long-running-job skip, failed
# deploy) out of every later diff. Prints nothing when there is no tag.
deploy_relevance_baseline() {
  local tag
  git fetch --quiet --tags --force origin >/dev/null 2>&1 || return 1
  tag=$(git tag -l 'v*.*.*.*' | sort -t. -k1,1 -k2,2n -k3,3n -k4,4n | tail -1)
  [ -n "$tag" ] || return 1
  git rev-parse --verify --quiet "${tag}^{commit}"
}

# 0 when this commit changes nothing that ships relative to the last release, 1 when it does or
# when that cannot be determined. Prints its reasoning, one line per decision, so the step log
# explains itself.
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

  # --no-renames: with rename detection a shipped file renamed into spec/ reports only the
  # destination, so the runtime file production still needs removed never appears in the diff.
  if ! files=$(git diff --name-only --no-renames "$base" "$commit" 2>/dev/null); then
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

# Call at the top of a main-branch step. Exits 0 (step passes, doing nothing) when the build is a
# no-op for production. Never exits non-zero: a broken relevance check must fall through to a
# normal deploy.
skip_if_production_noop() {
  local step="${1:-step}" decision
  [ "${BUILDKITE_BRANCH:-}" = "main" ] || return 0

  # Callers run under `set -e`; a plain `decision=$(...)` returning 1 would abort the step.
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