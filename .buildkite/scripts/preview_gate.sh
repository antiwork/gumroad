#!/bin/bash
set -euo pipefail

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") preview_gate.sh: $1${NC}"
}

# Every branch build gets a preview app. There is no opt-in.
#
# This used to require a `preview` label on an open PR, which meant the app only
# existed once someone remembered to ask for it — so the branches most worth
# looking at (pushed, green, no PR yet) had no environment at all, and reviewing
# a change meant reading a diff. Standing order (Sahil, 2026-08-01): "Don't use
# preview label anymore. Instead, generate a preview app for every deployment.
# It's totally fine to have 50+ even in parallel."
#
# Two consequences that follow, and are deliberate:
#   * No PR is required. A pushed branch is enough — the PR-less green branch is
#     exactly the case the old gate left uncovered.
#   * Concurrency is not capped here. Preview environments are per-branch and
#     independent, so 50+ in parallel is a supported state, not something to
#     defend against.
#
# `main` and `comp-assets-*` are excluded in pipeline.yml (`branches:`), not here:
# main deploys to production and comp-assets-* is the asset-cache builder.
PREVIEW_GITHUB_REPO="${PREVIEW_GITHUB_REPO:-antiwork/gumroad}"

# The PR number is looked up only to label the Buildkite annotation with
# something a human can click. It is NOT a gate — a missing PR must never stop
# the preview from deploying.
pr_number="${BUILDKITE_PULL_REQUEST:-false}"
if [ "$pr_number" = "false" ] || [ -z "$pr_number" ]; then
  pr_number=""
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    export GH_TOKEN="$GITHUB_TOKEN"
    source .buildkite/scripts/ensure_gh.sh
    ensure_gh
    # Never let a gh failure (rate limit, token scope, API blip) block the deploy.
    pr_number=$(gh pr list --repo "$PREVIEW_GITHUB_REPO" --head "$BUILDKITE_BRANCH" \
      --state open --json number --jq '.[0].number // empty' 2>/dev/null || true)
  fi
fi

if [ -n "$pr_number" ]; then
  logger "Deploying preview app for ${BUILDKITE_BRANCH} (PR #${pr_number})"
  buildkite-agent annotate \
    "Preview app deploying for PR #${pr_number} (\`${BUILDKITE_BRANCH}\`)." \
    --style "info" --context "preview" || true
else
  logger "Deploying preview app for ${BUILDKITE_BRANCH} (no open PR)"
  buildkite-agent annotate \
    "Preview app deploying for \`${BUILDKITE_BRANCH}\` (no open PR — every branch gets one)." \
    --style "info" --context "preview" || true
fi

buildkite-agent pipeline upload .buildkite/preview.yml
