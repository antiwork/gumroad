---
name: commit
description: Stage and commit changes with a clear, concise commit message.
argument-hint: [optional message hint]
allowed-tools: Bash(git *)
---

# Commit

Create a commit for the current changes.

## Steps

1. Run `git status` (without `-uall`) to see untracked and modified files.
2. Run `git diff` and `git diff --cached` to understand staged and unstaged changes.
3. Run `git log --oneline -5` to see recent commit style.
4. Stage the relevant files by name — avoid `git add -A` or `git add .`.
5. Write a commit message and commit.

If `$ARGUMENTS` is provided, use it as a hint for the message.

## Commit message rules

- Use the imperative mood ("Add", "Fix", "Remove", not "Added", "Fixes", "Removed").
- Be concise: one short sentence, ideally under 50 characters.
- Do NOT use conventional commit prefixes (no `feat:`, `fix:`, `chore:`, etc.).
- Do NOT add any `Co-Authored-By` or similar trailers.
- Focus on **what** changed and **why**, not how.
- If a second line is needed for context, keep it brief.

## Examples of good messages

- `Prevent discount code from being cleared on edit`
- `Add integration test for offer code persistence`
- `Remove unused legacy export helper`
- `Fix thumbnail missing in upsell insert`

$ARGUMENTS
