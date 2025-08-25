#!/usr/bin/env bash
set -euo pipefail

# Attempt to rerun upstream CI for a given PR when a run exists.
# Usage: scripts/ci/rerun_upstream_tests_for_pr.sh [PR_NUMBER]

PR_NUMBER=${1:-988}
REPO="antiwork/gumroad"
WORKFLOW_NAME="Tests"

# Ensure gh is authenticated
if ! gh auth status -h github.com >/dev/null 2>&1; then
  echo "error: gh not authenticated; run 'gh auth login'" >&2
  exit 1
fi

# Fetch PR head SHA
if ! PR_SHA=$(gh pr view "$PR_NUMBER" -R "$REPO" --json headRefOid --jq .headRefOid 2>/dev/null); then
  echo "error: unable to fetch PR #$PR_NUMBER from $REPO" >&2
  exit 1
fi

if [[ -z "${PR_SHA:-}" || "${PR_SHA}" == "null" ]]; then
  echo "error: PR head SHA not found" >&2
  exit 1
fi

echo "PR #$PR_NUMBER head SHA: $PR_SHA"

# Find the workflow id for Tests
if ! WORKFLOW_ID=$(gh api "repos/$REPO/actions/workflows" --jq ".workflows[] | select(.name==\"$WORKFLOW_NAME\") | .id" 2>/dev/null); then
  echo "error: unable to list workflows for $REPO" >&2
  exit 1
fi

if [[ -z "${WORKFLOW_ID:-}" ]]; then
  echo "error: workflow '$WORKFLOW_NAME' not found in $REPO" >&2
  exit 1
fi

echo "Workflow '$WORKFLOW_NAME' id: $WORKFLOW_ID"

# Look for a run for this PR (pull_request event) matching head_sha
RUN_ID=$(gh api "repos/$REPO/actions/workflows/$WORKFLOW_ID/runs?event=pull_request&per_page=100" \
  --jq ".workflow_runs[] | select(.head_sha==\"$PR_SHA\") | .id" 2>/dev/null | head -n1 || true)

if [[ -z "${RUN_ID:-}" ]]; then
  echo "No upstream pull_request run found for PR #$PR_NUMBER yet."
  echo "Note: $WORKFLOW_NAME currently triggers on 'push' and 'workflow_dispatch'. Maintainers may need to either:"
  echo "  • Manually 'Run workflow' (workflow_dispatch) on an upstream branch containing this PR's changes, or"
  echo "  • Add a 'pull_request' trigger to $WORKFLOW_NAME to run on fork PRs."
  exit 3
fi

echo "Found upstream run id: $RUN_ID — attempting rerun…"

# Try to rerun the upstream run
if gh run rerun "$RUN_ID" -R "$REPO" >/dev/null 2>&1; then
  echo "Successfully requested rerun for upstream run $RUN_ID."
  exit 0
else
  echo "Failed to request rerun (likely due to permissions). A maintainer needs to approve/trigger."
  exit 2
fi
