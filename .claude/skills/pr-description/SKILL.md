---
name: pr-description
description: >
  Generate a PR description for the current branch and its linked GitHub issue.
  Outputs to an unstaged markdown file in the repo root. Never creates or updates PRs.
  Triggers on: "generate PR description", "write PR description", "PR description",
  "describe this PR", "draft PR", or after completing implementation work when the user
  wants to prepare a PR. Also use when the user says "pr", "pull request description",
  or asks to summarize their branch changes for review.
---

# PR Description Generator

Generate a concise, high-quality PR description from the current branch and its linked GitHub issue. Output to an unstaged `.md` file — never publish or update a PR.

## Workflow

### 1. Gather Context

Run these in parallel:

```bash
# Current branch name
git branch --show-current

# Commits on this branch vs main
git log main..HEAD --oneline

# Full diff against main
git diff main...HEAD

# Check for linked issue number in branch name or commits
# Branch names often follow: username/issue-description or fix/NNNN-description
```

If the branch name or commits reference an issue number, fetch it:

```bash
gh issue view <number> --repo antiwork/gumroad --comments
```

If no issue number is found, ask the user.

### 2. Understand the Change

From the issue and diff, determine:

- **What problem was being solved** (or what feature was requested)
- **What approach was taken** (high-level concept, not file-by-file)
- **Whether this is a UI change** (look for view/component/CSS changes)

Read key changed files if the diff alone doesn't make the approach clear.

### 3. Write the Description

Use the template below. Adapt sections based on what's relevant — not every section is needed for every PR.

**Style rules:**

- Write in simple, direct language. Avoid jargon.
- Focus on _why_ and _how at a high level_ — not what files changed.
- No file change summaries or lists of modified files.
- No checklists.
- Succinct PR title: no "feat:" prefix, but "Fix:" is fine for bug fixes.
- Keep it concise. A few clear sentences beat a wall of text.

#### Template

```markdown
Fixes #<issue-number>

## Problem

[Why this change exists. What was broken or missing. 1-3 sentences max.]

## Approach

[High-level concept of the solution. What strategy was used and why.
NOT a list of file changes. If there were alternative approaches considered,
briefly explain why this one was chosen.]

<!-- BEFORE/AFTER — include for UI/CSS changes, delete this section otherwise
## Before/After

Before:
<!-- screenshot or video -->

After:

<!-- screenshot or video -->

Include: Desktop (light + dark) and Mobile (light + dark) if applicable.
-->

<!-- TEST RESULTS — include a screenshot of test suite passing locally
## Test Results

<!-- screenshot -->

-->

---

This PR was implemented with AI assistance using Claude Code for code generation. All code was self-reviewed.
```

See [references/example.md](references/example.md) for a well-received PR description example.

### 4. Output the File

Write the description to `gh-pr-draft.md` in the repo root. Do NOT stage or commit this file.

If `gh-pr-draft.md` already exists, overwrite it.

Tell the user the file was created and suggest they review it before posting.

## Important

- Use `gh` read-only only. Never create, comment on, or update PRs.
- Always fetch the GitHub issue — it provides critical context for the Problem section.
- Omit the Before/After section entirely for non-UI changes (remove the HTML comment too).
- Omit the Test Results section if not applicable (remove the HTML comment too).
- The AI disclaimer is always the last line, after a `---` separator.
