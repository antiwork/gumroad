---
name: test-confidence
description: AI-driven test execution. Opus decides what to run and how confident to be, based on your diff.
argument-hint: [--full to run to 100%] [--strict to halt on pre-existing failures]
allowed-tools: Bash(git *), Bash(bundle exec rspec *), Bash(cat *), Bash(find *), Bash(wc *), Bash(head *), Bash(tail *), Bash(grep *), Bash(bin/test-confidence *)
---

# Test Confidence

Run `bin/test-confidence` to have Opus 4.7 analyze your diff, decide the risk level, plan which tests to run and in what order, and set confidence milestones. The AI decides the shape of the curve based on this specific diff.

## Usage

```bash
bin/test-confidence            # Run to 99%, stop. Skips past pre-existing failures.
bin/test-confidence --full     # Run to 100%
bin/test-confidence --strict   # Halt on any failure, including pre-existing
```

`ANTHROPIC_API_KEY` is auto-sourced from `.env` if not exported.

If `$ARGUMENTS` is provided, pass it through: `bin/test-confidence $ARGUMENTS`

## How it works

1. Finds changed files (branch diff vs main for PR branches, local diff on main)
2. Hashes the diff and checks `tmp/test-confidence/` for a cached plan; reuses if found
3. Otherwise sends the diff + spec tree + touched directories to Opus 4.7 in one call
4. Opus returns a plan: risk level, ordered test list, confidence milestones
5. Script executes the plan, showing yellow progress bar toward 99%
6. At 99%, bar turns green. Safe to commit.
7. With `--full`, continues running remaining tests toward 100%

## Pre-existing failure detection

When a spec fails, the script applies a two-step check:

1. **Path heuristic** — does the failing spec file or its source counterpart (e.g., `app/models/user.rb` for `spec/models/user_spec.rb`) appear in the diff?
   - **In the diff** → real regression. Halt immediately.
   - **Not in the diff** → suspect pre-existing. Verify on merge-base.
2. **Merge-base verify** — re-run the failing rspec examples in a temporary worktree at the branch's merge-base with `main`.
   - **Still fails on merge-base** → confirmed pre-existing. Continue.
   - **Passes on merge-base** → cross-file regression caught. Halt.

The verify step is skipped (heuristic verdict trusted) when the diff includes a `db/migrate/*.rb` (DB schema drift) or `Gemfile.lock` (bundler drift), or when no merge-base is available. `--strict` skips both checks and halts on every failure.

Cost profile: zero overhead in the common no-failure case; verify only runs on heuristic-flagged "pre-existing" failures. Catches the dangerous direction (silent regression skipped) while keeping false-alarm investigation costs bounded.

The key insight: Opus decides ad hoc how many tests are needed for each confidence level. A comment-only change might need 2 tests for 99%. A payment model refactor might need 100.

## When to use

Run this before every commit. It replaces manually picking which specs to run.

$ARGUMENTS
