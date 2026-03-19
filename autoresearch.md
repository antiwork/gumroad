# Autoresearch: Fix remaining flaky tests in Gumroad CI

## Metrics
- **Primary**: flaky_test_count (unitless, lower is better)

## How to Run
`autoresearch.sh` — should emit `METRIC name=number` lines for flaky_test_count.

## What's Been Tried
- #1 crash 999 092b91e — Baseline attempt - script had bash arithmetic error with grep output
- #2 discard 97 092b91e — Baseline - metric counts too many (all payments_spec tests, not just flaky ones). Need better measurement.
- #3 crash 999 6591179 — Permission denied on script

## Plugin Checkpoint
- Last updated: 2026-03-19T19:04:02.283Z
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
