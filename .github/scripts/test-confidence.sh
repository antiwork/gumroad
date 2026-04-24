#!/bin/bash
# Test Confidence Score Calculator
#
# Computes a 0-100 confidence score based on test shard results.
# 0-98  = FAILING (not enough shards passed)
# 99    = NEUTRAL (high pass rate but not perfect)
# 100   = PASSING (all shards passed)
#
# The score is a weighted combination of:
# - Fast test pass rate (unit/controller tests, lower weight)
# - Slow test pass rate (E2E/system tests, higher weight because they catch integration issues)
#
# Usage: test-confidence.sh <fast_total> <fast_passed> <slow_total> <slow_passed>

set -euo pipefail

FAST_TOTAL="${1:?Usage: test-confidence.sh <fast_total> <fast_passed> <slow_total> <slow_passed>}"
FAST_PASSED="${2:?}"
SLOW_TOTAL="${3:?}"
SLOW_PASSED="${4:?}"

TOTAL=$((FAST_TOTAL + SLOW_TOTAL))
PASSED=$((FAST_PASSED + SLOW_PASSED))
FAILED=$((TOTAL - PASSED))

FAST_FAILED=$((FAST_TOTAL - FAST_PASSED))
SLOW_FAILED=$((SLOW_TOTAL - SLOW_PASSED))

# Perfect score: all shards passed
if [ "$FAILED" -eq 0 ]; then
  echo "100"
  exit 0
fi

# Calculate weighted confidence
# Fast tests: 30% weight (unit tests, less integration signal)
# Slow tests: 70% weight (E2E tests, high integration signal)
python3 << PYEOF
import math

fast_total = $FAST_TOTAL
fast_passed = $FAST_PASSED
slow_total = $SLOW_TOTAL
slow_passed = $SLOW_PASSED

fast_rate = fast_passed / fast_total if fast_total > 0 else 1.0
slow_rate = slow_passed / slow_total if slow_total > 0 else 1.0

# Weighted pass rate
weighted_rate = 0.3 * fast_rate + 0.7 * slow_rate

# Map to 0-98 range (since 99=neutral, 100=passing)
# Use a curve that penalizes failures heavily
# Any failure drops us below 99
if weighted_rate == 1.0:
    score = 100
elif weighted_rate >= 0.99:
    score = 99  # neutral: very close but not perfect
else:
    # Scale 0-0.99 to 0-98
    # Apply a curve that makes low pass rates score very low
    score = int(weighted_rate * 98)

# Additional penalty: each slow test failure is more costly
slow_failed = slow_total - slow_passed
fast_failed = fast_total - fast_passed

if slow_failed > 0:
    # Each slow test failure costs more confidence
    penalty = min(slow_failed * 3, 30)
    score = max(0, score - penalty)

if fast_failed > 0:
    penalty = min(fast_failed * 1, 10)
    score = max(0, score - penalty)

print(score)
PYEOF
