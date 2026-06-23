#!/bin/bash
set -euo pipefail

GREEN="\033[0;32m"
NC="\033[0m"
logger() {
  echo -e "${GREEN}$(date "+%Y/%m/%d %H:%M:%S") preview_gate.sh: $1${NC}"
}

PREVIEW_LABEL="preview"
PREVIEW_GITHUB_REPO="${PREVIEW_GITHUB_REPO:-antiwork/gumroad}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  logger "Error: GITHUB_TOKEN is not set"
  exit 1
fi
export GH_TOKEN="$GITHUB_TOKEN"

source .buildkite/scripts/ensure_gh.sh
ensure_gh

pr_number="${BUILDKITE_PULL_REQUEST:-false}"
if [ "$pr_number" = "false" ] || [ -z "$pr_number" ]; then
  pr_number=$(gh pr list --repo "$PREVIEW_GITHUB_REPO" --head "$BUILDKITE_BRANCH" --state open --json number --jq '.[0].number // empty')
fi

if [ -z "$pr_number" ]; then
  logger "No open PR for ${BUILDKITE_BRANCH}; skipping preview app"
  buildkite-agent annotate "No open PR for \`${BUILDKITE_BRANCH}\`. Open a PR and add the \`${PREVIEW_LABEL}\` label to deploy a preview app." --style "info" --context "preview" || true
  exit 0
fi

has_label=$(gh pr view "$pr_number" --repo "$PREVIEW_GITHUB_REPO" --json labels --jq "any(.labels[]; .name == \"${PREVIEW_LABEL}\")")
if [ "$has_label" != "true" ]; then
  logger "PR #${pr_number} is not labeled '${PREVIEW_LABEL}'; skipping preview app"
  buildkite-agent annotate "Add the \`${PREVIEW_LABEL}\` label to PR #${pr_number} to deploy a preview app." --style "info" --context "preview" || true
  exit 0
fi

logger "PR #${pr_number} is labeled '${PREVIEW_LABEL}'; provisioning preview app"
buildkite-agent pipeline upload .buildkite/preview.yml
