---
name: test-confidence
description: Run tests in priority order based on your diff. Shows a live confidence score that climbs as tests pass. Run this before committing.
argument-hint: [threshold, e.g. 0.99]
allowed-tools: Bash(git *), Bash(bundle exec rspec *), Bash(cat *), Bash(find *), Bash(wc *), Bash(head *), Bash(tail *), Bash(grep *)
---

# Test Confidence

Run tests ranked by relevance to your diff. Confidence climbs in real-time as each test passes.

**Run this before every commit.** Stop when confidence is high enough.

## How it works

1. Analyze the diff to identify changed files and understand the nature of changes
2. Map changes to the most relevant test files (direct tests first, then integration, then broad)
3. Run tests one batch at a time in priority order
4. After each batch, calculate and display a confidence score
5. Stop early when confidence crosses the threshold

## Steps

### 1. Get the diff

```bash
git diff --name-only HEAD
git diff --stat HEAD
git diff HEAD -- $(git diff --name-only HEAD | grep -E '\.(rb|ts|tsx|js|jsx)$' | head -20)
```

If there are no changes, say so and stop.

### 2. Determine the threshold

Default threshold: **0.99** (99% confidence).

If `$ARGUMENTS` provides a number (e.g. `0.999`, `0.95`), use that instead.

For changes touching payment/billing code (`app/billing/`, `app/payments/`, `app/models/purchase.rb`, anything Stripe-related), automatically raise the threshold to **0.9999**.

### 3. Map changes to tests

Analyze the diff and build a prioritized test plan. Think about:

**Wave 1 — Direct tests (target: 80% confidence)**
- Unit tests for the exact files changed (e.g. `app/models/foo.rb` → `spec/models/foo_spec.rb`)
- Tests that directly `require` or reference the changed code

**Wave 2 — Integration tests (target: 95% confidence)**
- Controller/request specs that exercise the changed code paths
- Related model specs that depend on the changed models
- Service specs that call into changed code

**Wave 3 — Broad coverage (target: 99% confidence)**
- Feature/system specs that exercise user flows touching the changed area
- Any specs that interact with the same database tables
- Tests for code that calls the changed code (reverse dependencies)

**Wave 4 — Full suite (target: 99.99% confidence)**
- All remaining test files (only if threshold demands it)

To find related tests:
```bash
# Direct test file mapping
find spec -name "$(basename app/models/foo.rb | sed 's/.rb/_spec.rb/')" -type f

# Tests that reference the changed class/module
grep -rl "ClassName" spec/ --include="*.rb" | head -20

# Tests in the same domain area
find spec/models/ spec/controllers/ spec/requests/ -name "*related_name*" -type f
```

### 4. Run tests in waves with live confidence

Run each wave and report confidence after each batch. Use this exact output format:

```
═══════════════════════════════════════════════════
  TEST CONFIDENCE
═══════════════════════════════════════════════════

  Wave 1/4 — Direct unit tests
  ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓░░░░ 80.0%
  ✅ 12 passed · 0 failed · 3.2s

  Running: spec/models/offer_code_spec.rb ...

═══════════════════════════════════════════════════
```

Run tests like this:
```bash
bundle exec rspec spec/path/to/test_spec.rb --format progress --no-color 2>&1
```

**Batch size:** Run 3-5 test files per batch for responsive feedback. After each batch:
- Update the confidence display
- If any test FAILS: stop immediately, report the failure, set confidence to 0%
- If confidence ≥ threshold: stop, report success

### 5. Confidence calculation

Confidence is based on which waves have passed:

| Passed waves | Confidence |
|-------------|------------|
| None yet | 0% |
| Wave 1 (direct tests) | 80% |
| Wave 2 (integration) | 95% |
| Wave 3 (broad coverage) | 99% |
| Wave 4 (full suite) | 99.99% |

Within a wave, confidence scales linearly. For example, if wave 2 has 10 test files and 5 have passed:
- Wave 1 complete = 80%
- Half of wave 2 = 80% + (95% - 80%) × 0.5 = 87.5%

If a test **fails**, confidence drops to 0% and you stop immediately.

### 6. Final report

When done (either threshold met or all waves complete), print:

```
═══════════════════════════════════════════════════
  ✅ TEST CONFIDENCE: 99.2%  (threshold: 99%)
═══════════════════════════════════════════════════

  Wave 1  ✅  12 tests  3.2s   Direct unit tests
  Wave 2  ✅   8 tests  5.1s   Integration tests
  Wave 3  ✅   4 tests  2.8s   Broad coverage
  Wave 4  ⬜  ~1200 tests       Full suite (skipped)

  Total: 24 tests in 11.1s (of ~1200 in repo)
  Confidence crossed 99% after 20 tests.

═══════════════════════════════════════════════════
```

Or if a test fails:

```
═══════════════════════════════════════════════════
  ❌ TEST CONFIDENCE: 0%  — REGRESSION DETECTED
═══════════════════════════════════════════════════

  Wave 1  ❌  spec/models/offer_code_spec.rb FAILED
  
  Fix the failing test before committing.

═══════════════════════════════════════════════════
```

## Important notes

- **This replaces full test suite runs for pre-commit verification.** You do NOT need to run the entire suite locally. Run this skill, and if confidence meets the threshold, you're good to commit.
- If the diff is trivial (docs, comments, whitespace), wave 1 alone should suffice.
- If the diff touches core models or payment code, expect to need waves 1-3 minimum.
- Always run at least wave 1. Never skip testing entirely.

$ARGUMENTS
