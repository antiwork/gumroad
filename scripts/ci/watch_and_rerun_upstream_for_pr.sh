#!/usr/bin/env bash
set -euo pipefail

# Watch for an upstream CI run tied to a PR and attempt to rerun it when it exists.
# Usage: scripts/ci/watch_and_rerun_upstream_for_pr.sh [PR_NUMBER] [max_attempts=60] [sleep_secs=120]

PR_NUMBER=${1:-988}
MAX_ATTEMPTS=${2:-60}
SLEEP_SECS=${3:-120}
REPO="antiwork/gumroad"
ATTEMPT_SCRIPT="scripts/ci/rerun_upstream_tests_for_pr.sh"

if [[ ! -x "$ATTEMPT_SCRIPT" ]]; then
  echo "error: $ATTEMPT_SCRIPT not found or not executable" >&2
  exit 1
fi

echo "Watching for upstream CI runs for PR #$PR_NUMBER on $REPO..."
for (( i=1; i<=MAX_ATTEMPTS; i++ )); do
  ts=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$ts] attempt $i/$MAX_ATTEMPTS: checking..."
  if output=$($ATTEMPT_SCRIPT "$PR_NUMBER" 2>&1); then
    echo "[$ts] rerun requested successfully"
    gh pr comment "$PR_NUMBER" -R "$REPO" --body "Auto-update: Requested a re-run of the upstream 'Tests' workflow for this PR. If permissions allow, jobs should restart shortly."
    exit 0
  else
    rc=$?
    echo "[$ts] attempt script exit code: $rc"
    echo "$output"
    if [[ $rc -eq 3 ]]; then
      # No run yet; keep waiting
      sleep "$SLEEP_SECS"
      continue
    elif [[ $rc -eq 2 ]]; then
      # Permission issue; notify and exit
      gh pr comment "$PR_NUMBER" -R "$REPO" --body "Auto-update: Tried to re-run upstream CI but do not have permission. A maintainer needs to click 'Re-run jobs' or 'Run workflow' from Actions."
      exit 0
    else
      # Unexpected error; bail out
      gh pr comment "$PR_NUMBER" -R "$REPO" --body "Auto-update: Attempt to re-run upstream CI encountered an error. Details:\n\n\`\`\`\n$output\n\`\`\`"
      exit 1
    fi
  fi
done

echo "Reached max attempts ($MAX_ATTEMPTS) without finding an upstream run."
exit 0
