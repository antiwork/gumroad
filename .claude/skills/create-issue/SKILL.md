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

Structure:

**## What**
The problem, concretely. Include:

- What's happening and what the impact is
- Who's affected (users, sellers, internal team)
- Quantify with data when possible (error rates, support ticket counts)
- Link to related issues, Slack threads, or prior attempts
- Mention workarounds people are using and why they're insufficient

**## Why**
The root cause. Explain the technical reason the problem exists — not just symptoms. Reference code areas and behaviors (e.g., "the PayPal webhook handler" or "the dispute resolution flow"), not specific file paths or line numbers — those change. This is what makes the issue actionable rather than just a complaint.

**## Proposed solution**
High-level direction that's technically sound but not overly prescriptive. Give enough guidance that someone can start working without a long investigation phase, while leaving room for implementation decisions:

- Name the approach and why it's the right one
- If there are API constraints or non-obvious technical details, explain them (link to external docs when relevant)
- Number the parts if the solution has multiple steps
- Note alternatives considered and why they were rejected, if relevant
- Don't dictate implementation details like exact method signatures or class names — describe what needs to happen, not exactly how to code it

**## Acceptance criteria**
Checkboxes. Each one should be independently testable. Cover:

- The happy path
- Key edge cases
- Things that should NOT change (e.g., "Stripe behavior is unchanged")

**## Edge cases** (when applicable)
Call out non-obvious scenarios: race conditions, ordering issues, backward compatibility, migration concerns.

### 4. Output

Write to `gh-issue-draft.md` in the repo root. Do NOT stage or commit.

If the issue should be split into sub-issues, write the parent issue first, then add a `## Sub-issues` section at the end listing each sub-issue with a one-line summary. The user can split them manually.

## Style

- Concise and direct. No jargon, no filler.
- Ground claims in data or code references — don't just say "this is a problem," show it.
- Use `product` not `link`, `buyer`/`seller` not `customer`/`creator` per CONTRIBUTING.md.
- Link to external docs (API references, etc.) where they add clarity.
- Reference code by area or concept ("the dispute webhook handler"), not by file:line — those change.
- The issue is public (open source). It must be **self-contained**: an OSS contributor who has no access to prod, Slack, or internal tools should have everything they need to implement it without asking follow-up questions.
- Include aggregated data when it quantifies the problem. **Never include PII** — no emails, user IDs, names, or payment details.

## Important

- Use `gh` read-only only. Never create issues via CLI.
- The user reviews and posts manually — just write the best possible draft.
