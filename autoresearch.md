# Autoresearch: Fix remaining flaky tests in Gumroad CI

## Metrics
- **Primary**: flaky_test_count (unitless, lower is better)

## How to Run
`autoresearch.sh` — should emit `METRIC name=number` lines for flaky_test_count.

## What's Been Tried
- #1 crash 999 092b91e — Baseline attempt - script had bash arithmetic error with grep output
- #2 discard 97 092b91e — Baseline - metric counts too many (all payments_spec tests, not just flaky ones). Need better measurement.
- #3 crash 999 6591179 — Permission denied on script
- #4 keep 98 6591179 — Baseline: 98 flaky test patterns (90 payments unstubbed, 7 taxes no-block, 1 preorder)
- #5 crash 999 294f5e3 — Wrong branch, fixing

## Plugin Checkpoint
- Last updated: 2026-03-19T19:08:43.175Z
- Runs tracked: 5 current / 5 total
- Baseline: 999
- Best kept: 98
- Confidence: n/a
- Last logged run: #5 crash 294f5e3 — Wrong branch, fixing
- Pending run awaiting log_experiment: cd /Users/gumclaw/.openclaw/workspace/repos/gumroad && bash autoresearch.sh (8)

Z
- Runs tracked: 5 current / 5 total
- Baseline: 999
- Best kept: 98
- Confidence: n/a
- Last logged run: #5 crash 294f5e3 — Wrong branch, fixing

Z
- Runs tracked: 4 current / 4 total
- Baseline: 999
- Best kept: 98
- Confidence: 2.0x noise floor - improvement is likely real
- Last logged run: #4 keep 6591179 — Baseline: 98 flaky test patterns (90 payments unstubbed, 7 taxes no-block, 1 preorder)

Z
- Runs tracked: 3 current / 3 total
- Baseline: 999
- Best kept: n/a
- Confidence: n/a
- Last logged run: #3 crash 6591179 — Permission denied on script
- Pending run awaiting log_experiment: cd /Users/gumclaw/.openclaw/workspace/repos/gumroad && bash autoresearch.sh (98)

Z
- Runs tracked: 3 current / 3 total
- Baseline: 999
- Best kept: n/a
- Confidence: n/a
- Last logged run: #3 crash 6591179 — Permission denied on script

Z
- Runs tracked: 2 current / 2 total
- Baseline: 999
- Best kept: n/a
- Confidence: n/a
- Last logged run: #2 discard 092b91e — Baseline - metric counts too many (all payments_spec tests, not just flaky ones). Need better measurement.
- Pending run awaiting log_experiment: cd /Users/gumclaw/.openclaw/workspace/repos/gumroad && ./autoresearch.sh (n/a)
