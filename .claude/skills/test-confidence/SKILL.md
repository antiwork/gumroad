---
name: test-confidence
description: AI-driven test execution. Opus decides what to run and how confident to be, based on your diff.
argument-hint: [--full to run to 100%]
allowed-tools: Bash(git *), Bash(bundle exec rspec *), Bash(cat *), Bash(find *), Bash(wc *), Bash(head *), Bash(tail *), Bash(grep *), Bash(bin/test-confidence *)
---

# Test Confidence

Run `bin/test-confidence` to have Opus 4.7 analyze your diff, decide the risk level, plan which tests to run and in what order, and set confidence milestones. The AI decides the shape of the curve based on this specific diff.

## Usage

```bash
bin/test-confidence          # Run to 99%, stop
bin/test-confidence --full   # Run to 100%
```

Requires `ANTHROPIC_API_KEY` in your environment.

If `$ARGUMENTS` is provided, pass it through: `bin/test-confidence $ARGUMENTS`

## How it works

1. Finds changed files (branch diff vs main for PR branches, local diff on main)
2. Sends the diff + full spec file list to Opus 4.7 in one call
3. Opus returns a plan: risk level, ordered test list, confidence milestones
4. Script executes the plan, showing yellow progress bar toward 99%
5. At 99%, bar turns green. Safe to commit.
6. With `--full`, continues running remaining tests toward 100%

The key insight: Opus decides ad hoc how many tests are needed for each confidence level. A comment-only change might need 2 tests for 99%. A payment model refactor might need 100.

## When to use

Run this before every commit. It replaces manually picking which specs to run.

$ARGUMENTS
