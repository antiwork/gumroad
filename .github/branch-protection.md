# Branch Protection Configuration

This document outlines the recommended branch protection settings for the main branch to ensure code quality and security.

## Recommended Settings

### Required Status Checks

- [x] Require branches to be up to date before merging
- [x] Require status checks to pass before merging

**Required checks:**

- `Brakeman` - Ruby security scanner
- `bundler-audit` - Dependency vulnerability scanner
- `CodeQL (ruby)` - Static code analysis for Ruby
- `CodeQL (javascript)` - Static code analysis for JavaScript/TypeScript
- `npm audit` - JavaScript dependency vulnerability scanner

### Pull Request Reviews

- [x] Require pull request reviews before merging
- [x] Required number of reviewers: 1
- [x] Dismiss stale reviews when new commits are pushed
- [x] Require review from code owners

### Other Restrictions

- [x] Enforce all configured restrictions for administrators
- [ ] Restrict pushes that create files larger than 100MB
- [ ] Restrict force pushes
- [ ] Allow deletions

## Manual Setup Instructions

Since branch protection requires admin privileges, follow these steps:

1. Navigate to Settings > Branches in the GitHub repository
2. Add a rule for the `main` branch
3. Configure the settings as outlined above
4. Save the rule

## Automation with GitHub CLI

For repository administrators, you can apply these settings using:

```bash
gh api --method PUT repos/:owner/:repo/branches/main/protection \
  --raw-field required_status_checks='{"strict":true,"contexts":["Brakeman","bundler-audit","CodeQL (ruby)","CodeQL (javascript)","npm audit"]}' \
  --raw-field enforce_admins=true \
  --raw-field required_pull_request_reviews='{"required_approving_review_count":1,"dismiss_stale_reviews":true,"require_code_owner_reviews":true}' \
  --raw-field restrictions=null
```

## Dependabot Auto-merge Setup

To enable safe auto-merging of Dependabot PRs, add this workflow file to automate dependency updates:

```yaml
# .github/workflows/dependabot-automerge.yml
name: Dependabot auto-merge
on: pull_request

permissions:
  contents: write
  pull-requests: write

jobs:
  dependabot:
    runs-on: ubuntu-latest
    if: github.actor == 'dependabot[bot]'
    steps:
      - name: Dependabot metadata
        id: metadata
        uses: dependabot/fetch-metadata@v1
        with:
          github-token: "${{ secrets.GITHUB_TOKEN }}"

      - name: Enable auto-merge for Dependabot PRs
        if: steps.metadata.outputs.update-type == 'version-update:semver-patch' || steps.metadata.outputs.update-type == 'version-update:semver-minor'
        run: gh pr merge --auto --merge "$PR_URL"
        env:
          PR_URL: ${{github.event.pull_request.html_url}}
          GITHUB_TOKEN: ${{secrets.GITHUB_TOKEN}}
```

This configuration ensures that:

- Security scans must pass before merging
- Code is reviewed before merging
- Dependencies are kept up to date automatically
- The main branch remains stable and secure
