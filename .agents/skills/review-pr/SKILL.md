---
name: review-pr
description: >
  Review GitHub pull requests for the Gumroad codebase against project guidelines, code quality,
  and correctness. Use when the user wants to review a PR, check new comments on a PR, provide
  feedback on code changes, or asks about PR quality. Triggers on: "review PR", "review this PR",
  "check PR #NNN", any GitHub PR URL (e.g. https://github.com/antiwork/gumroad/pull/NNNN),
  "what's new on the PR", "check comments", "review the diff", "give feedback on this PR",
  or requests to evaluate code changes in a pull request.
---

# PR Review

Review pull requests for code quality, correctness, and CONTRIBUTING.md compliance.

**Scope boundary**: This skill evaluates _how the code is written_. For evaluating _whether the PR solves the right problem_, use the `issue-detective` skill instead.

## Workflow

### 1. Fetch PR Context

```bash
gh pr view <number> --repo antiwork/gumroad
gh pr diff <number> --repo antiwork/gumroad
gh pr view <number> --repo antiwork/gumroad --comments
gh api repos/antiwork/gumroad/pulls/<number>/comments
```

Also read `CONTRIBUTING.md` from the repo root — it's the source of truth for all guideline checks.

Note PR status (draft, closed, merged). Skip review if merged or closed unless user insists.

### 2. Understand the Change

From the diff and description, determine:

- What changed and why (read the linked issue if referenced)
- Bug fix, feature, refactor, or chore
- Which layers are affected (frontend, backend, both, tests only)
- Size and complexity

Read key modified files in full when the diff alone is insufficient to understand context.

### 3. Review

Run these review passes on the diff:

**Pass 1 — Bugs and Logic Errors**
Wrong conditionals, missing edge cases, race conditions, nil/null handling, off-by-one errors, security vulnerabilities (injection, XSS, CSRF). Focus on code paths introduced or modified by the PR.

**Pass 2 — CONTRIBUTING.md Compliance**
Check the diff against every applicable rule in CONTRIBUTING.md (code standards, naming conventions, testing standards, Sidekiq patterns, PR structure, etc.). The file is the single source of truth — do not maintain a separate checklist.

**Pass 3 — Code Clarity**
Evaluate readability and maintainability of new/modified code. See [references/review-guidance.md](references/review-guidance.md) for what to flag vs what to leave alone. The goal is clear, explicit code — not clever or compact code.

**Pass 4 — PR Structure**
AI disclosure, description quality (explains _why_), before/after for UI changes, test results, appropriate size — all per CONTRIBUTING.md.

### 4. Score and Filter

Assign each finding a confidence score (0–100): how likely is this a genuine problem?

**Keep** findings >= 80. **Drop** findings below 80.

See [references/review-guidance.md](references/review-guidance.md) for noise filtering rules and severity levels.

### 5. Report

```
## Summary

[1-2 sentences: what the PR does and overall assessment]

## Issues

### [critical|important|suggestion] Title
**File:** `path/to/file.rb:NN`
**Confidence:** NN/100

[Concise explanation and fix suggestion if straightforward.]

...

## Checklist

[CONTRIBUTING.md items that are missing — e.g., no AI disclosure, no before/after, missing tests]

## Verdict

[approve / request-changes / comment-only — with brief justification]
```

Write the review to `gh-pr-review.md` in the repo root. Do NOT stage or commit. Do NOT post to GitHub.

### 6. Iterate

When the user asks to re-check a PR (new comments, updated diff):

```bash
gh pr view <number> --repo antiwork/gumroad --comments
gh api repos/antiwork/gumroad/pulls/<number>/comments
gh pr diff <number> --repo antiwork/gumroad
```

Focus on what changed since the last review. Don't repeat prior findings unless still unaddressed.

## Important

- Use `gh` read-only only. Never approve, comment on, or request changes via CLI.
- Review what the PR _introduces_ — not pre-existing code.
- Be direct and concise. No filler praise.
- Prioritize substantive issues over cosmetic ones.
- When unsure, state uncertainty rather than false confidence.
- For large PRs (1k+ lines), note the PR should be broken up.
