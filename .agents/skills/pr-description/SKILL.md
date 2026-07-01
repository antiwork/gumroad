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

## ⛔ RULE #0 — MEDIA EVIDENCE IS MANDATORY (read before anything else)

**CONTRIBUTING.md line 17 is a hard `Must`: _"Include a video for every PR."_ This is the single most important requirement for any PR that touches product — do NOT treat it as optional, and do NOT rationalize a change as "too small to film."**

- **Any product/UI change** (a view, component, CSS, layout, mobile behavior, copy a user sees, a button, spacing, colors — anything a user could perceive): a **before/after VIDEO or screenshots are REQUIRED**, showing **desktop + mobile, light + dark** where applicable. A mobile-layout or CSS tweak is exactly the kind of change that MUST have visual proof — that is the whole point of the rule. "Minor layout fix" is NOT an exemption; it is the primary target.
- **Non-user-facing change** (pure backend/refactor/config): a **short walkthrough video** of the relevant existing functionality is still required to demonstrate nothing broke.
- If you do not yet have the media, the PR is NOT ready. Capture it first (boot the app, take the screenshots/video, store under `qa-media/pr-<number>-<desc>.<ext>`, reference via raw GitHub URL) — do NOT emit a description with an empty or deleted Before/After section for a product change.

**The Before/After section below is NOT deletable for product changes.** The only case where it may be omitted is a genuinely non-visual change, and even then a walkthrough video goes in its place. When in doubt: include media.

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

Follow the PR description structure in CONTRIBUTING.md. The template below implements it:

Adapt the prose sections to what's relevant — but the **Before/After media section is mandatory for any product/UI change** and is never dropped to save effort (RULE #0). "Not every section is needed" applies to optional prose, never to the media evidence on a visual change.

**Style rules:**

- Write in simple, direct language. Avoid jargon.
- Focus on _what_ and _why_ — not what files changed.
- No file change summaries or lists of modified files.
- No checklists.
- Succinct PR title: no "feat:" prefix, but "Fix:" is fine for bug fixes.
- Keep it concise. A few clear sentences beat a wall of text.

#### Template

```markdown
Fixes #<issue-number>

## What

[What this PR does. Concrete changes — not a list of files.
For features: what was built. For fixes: what was wrong and what was changed.]

## Why

[Why this change exists and why this approach over alternatives.
Business or user rationale. Strategic context if relevant.]

<!-- BEFORE/AFTER — REQUIRED for every product/UI change (see RULE #0). Do NOT delete this
     section for anything a user can perceive. Video required; screenshots acceptable for
     static layout. For non-visual changes, replace with a short walkthrough video instead.
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

This PR was implemented with AI assistance using [specific model, e.g., Claude Opus 4.6].

Prompts used:

<!-- chronological, verbatim if under ~100 chars otherwise summarized, skip pure confirmations -->

- "[first prompt that shaped the code]"
- "[next prompt]"
```

See [references/example.md](references/example.md) for a well-received PR description example.

### 4. Output the File

Write the description to `gh-pr-draft.md` in the repo root. Do NOT stage or commit this file.

If `gh-pr-draft.md` already exists, overwrite it.

Tell the user the file was created and suggest they review it before posting.

## Important

- Use `gh` read-only only. Never create, comment on, or update PRs.
- Always fetch the GitHub issue — it provides critical context for the Problem section.
- **NEVER omit the Before/After section for a product/UI change** (see RULE #0 — media is a hard `Must`). It may only be dropped for a genuinely non-visual change, and even then a short walkthrough video replaces it. If you catch yourself deleting Before/After on a UI/CSS/layout/mobile PR, stop — that is the exact rule violation this skill exists to prevent.
- Omit the Test Results section only if there are genuinely no tests to run (remove the HTML comment too); otherwise include the passing-tests screenshot.
- The AI disclosure format follows CONTRIBUTING.md.
