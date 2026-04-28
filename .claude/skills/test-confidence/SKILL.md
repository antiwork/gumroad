---
name: test-confidence
description: Run tests ranked by relevance to your diff. Confidence climbs continuously from 0% to 100%. Stop when you're confident enough.
argument-hint: [threshold, e.g. 0.99]
allowed-tools: Bash(git *), Bash(bundle exec rspec *), Bash(cat *), Bash(find *), Bash(wc *), Bash(head *), Bash(tail *), Bash(grep *), Bash(bin/test-confidence *)
---

# Test Confidence

Run `bin/test-confidence` to execute tests ranked by relevance to your diff. Confidence climbs continuously from 0% to 100% as each test passes. No waves, no stages. Just a stream of tests, most important first.

## Usage

```bash
bin/test-confidence              # Stop at 99%
bin/test-confidence 0.95         # Stop at 95% (quick sanity check)
bin/test-confidence 1.0          # Run everything
bin/test-confidence --no-ai      # Convention mapping only
```

If `$ARGUMENTS` provides a number, pass it through: `bin/test-confidence $ARGUMENTS`

## How it works

1. Finds your changed files via `git diff`
2. Builds a single ordered queue: direct specs first, then specs referencing your classes, then same-directory specs, then everything else
3. Optionally calls Sonnet to reorder by likelihood of catching a regression
4. Runs tests one at a time. After each pass, confidence updates on a Pareto curve (early tests contribute more since they're the most relevant)
5. Stops the moment confidence crosses the threshold

The confidence model:
- 10% of tests (most relevant) → ~70% confidence
- 30% of tests → ~92% confidence  
- 50% of tests → ~98% confidence
- 100% of tests → 100% confidence

If any test fails, it stops immediately and reports the failure.

## When to use

Run this before every commit. It replaces manually picking which specs to run.

$ARGUMENTS
