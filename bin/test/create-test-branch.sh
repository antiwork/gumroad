# List all open PRs from external contributors (cross-repo)
gh pr list --repo "$REPO" --state open --json number,headRefName,isCrossRepository --jq '.[] | select(.isCrossRepository == true) | [.number, .headRefName] | @tsv' | while IFS=$'\t' read -r pr_number pr_head_ref; do
  echo "Processing PR #$pr_number from external contributor"

  # Check out the PR locally
  gh pr checkout "$pr_number"

  # Create a test/<branch> name
  NEW_BRANCH="test/${pr_head_ref}"
  git checkout -b "$NEW_BRANCH"

  # Push it to your repo
  git push origin "$NEW_BRANCH"

  echo "✅ Pushed PR #$pr_number to branch: $NEW_BRANCH"
  echo
done
