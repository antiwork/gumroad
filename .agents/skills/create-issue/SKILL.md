---
name: create-issue
description: >
  Draft GitHub issues for the Gumroad codebase. Outputs to an unstaged markdown file in the repo
  root. Never creates issues on GitHub. Triggers on: "create issue", "write issue", "draft issue",
  "write a bug report", "file an issue", "create a ticket", or when the user describes a problem
  or feature they want to turn into a GitHub issue.
---

# Issue Drafting

Draft well-structured GitHub issues. Output to an unstaged `.md` file — never post to GitHub.

## Workflow

### 1. Understand the Problem

Gather context from the user. Ask clarifying questions if needed:

- What's happening vs what should happen?
- Who's affected and how often?
- Any workarounds in use?
- Is there data that quantifies the impact?

If the user points to code, trace the relevant paths to understand the root cause. Include aggregated, anonymized data that quantifies the impact when available (e.g., "99 purchases across 82 sellers are in this state"). Never include PII — no emails, names, IDs, or payment details.

### 2. Decide: Single Issue or Parent + Sub-issues

Before writing, assess the scope:

**Single issue** when:

- One clear problem with one solution path
- The fix would be one PR (~100 LOC per CONTRIBUTING.md)
- No independent workstreams

**Parent + sub-issues** when:

- The solution has multiple independently shippable parts
- Different parts could be worked on in parallel or by different people
- The total scope would exceed one reasonably-sized PR
- There's a logical sequence (e.g., API integration → webhook fix → backfill)

If suggesting sub-issues, number the solution parts clearly and note which can be done independently vs which depend on each other. Write the parent issue as the full document, then note where to split.

### 3. Write the Issue

Follow the structure in CONTRIBUTING.md.

**Title** — Carries most of the weight. Specific and actionable.

**## What**
What needs to change. Be concrete — current vs desired behavior, who is affected, checkbox task list for multiple deliverables.

**## Why**
Why this matters — business rationale or user impact, root cause if it's a bug, links to related issues or prior discussions.

### 4. Output

Write to `gh-issue-draft.md` in the repo root. Do NOT stage or commit.

If the issue should be split into sub-issues, write the parent issue first, then add a `## Sub-issues` section at the end listing each sub-issue with a one-line summary. The user can split them manually.

## Style

Follow CONTRIBUTING.md for terminology and tone. Additionally:

- Concise and direct. No jargon, no filler.
- Ground claims in data or code references.
- Reference code by area or concept ("the dispute webhook handler"), not by file:line.
- The issue is public (open source). Self-contained for OSS contributors with no access to internal tools.

## Important

- Use `gh` read-only only. Never create issues via CLI.
- The user reviews and posts manually — just write the best possible draft.
