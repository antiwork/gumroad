#!/usr/bin/env bash
# Local secret scanner aligned with CI behavior. Prints only filenames, never matched contents.
set -euo pipefail

ROOT_DIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
cd "$ROOT_DIR"

ALLOWLIST=(
  "spec/support/test_secrets_manager.rb"
  "spec/support/fixtures/stripe_connect_omniauth.json"
)

CRITICAL_PATTERNS=(
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'
  'AKIA[0-9A-Z]{16}'
  'SG\.[A-Za-z0-9_-]{10,}'
  'sk_live_[A-Za-z0-9]{10,}'
  'whsec_[A-Za-z0-9]{10,}'
)
INFO_PATTERNS=(
  'RAILS_MASTER_KEY'
  'sk_test_[A-Za-z0-9]{10,}'
)

RG_BASE_EXCLUDES=("--hidden" "--glob" "!node_modules/**" "--glob" "!.git/**" "--glob" "!log/**" "--glob" "!.env*" )
for f in "${ALLOWLIST[@]}"; do
  RG_BASE_EXCLUDES+=("-g" "!$f")
done
RG_EXCLUDES_OUTSIDE_TESTS=("${RG_BASE_EXCLUDES[@]}" "-g" "!spec/**" "-g" "!test/**")
RG_INCLUDES_TESTS=("--hidden" "-g" "!node_modules/**" "-g" "!.git/**" "-g" "!log/**" "-g" "!.env*" "-g" "spec/**" "-g" "test/**")

FAIL=0
CRIT_OUT=()
CRIT_TEST=()
INFO_OUT=()

if ! command -v rg >/dev/null 2>&1; then
  echo "ripgrep (rg) is required. Install it and retry." >&2
  exit 2
fi

for pat in "${CRITICAL_PATTERNS[@]}"; do
  mapfile -t HITS < <(rg -l "${RG_EXCLUDES_OUTSIDE_TESTS[@]}" -e "$pat" . || true)
  ((${#HITS[@]})) && CRIT_OUT+=("${HITS[@]}") && echo "[critical-outside] $pat" >&2 && FAIL=1

done
for pat in "${CRITICAL_PATTERNS[@]}"; do
  mapfile -t HITS < <(rg -l "${RG_INCLUDES_TESTS[@]}" -e "$pat" . || true)
  ((${#HITS[@]})) && CRIT_TEST+=("${HITS[@]}") && echo "[critical-tests] $pat" >&2

done
for pat in "${INFO_PATTERNS[@]}"; do
  mapfile -t HITS < <(rg -l "${RG_BASE_EXCLUDES[@]}" -e "$pat" . || true)
  ((${#HITS[@]})) && INFO_OUT+=("${HITS[@]}") && echo "[info] $pat" >&2

done

# Print summary
crit_out_count=$(printf '%s\n' "${CRIT_OUT[@]}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')
crit_test_count=$(printf '%s\n' "${CRIT_TEST[@]}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')
info_count=$(printf '%s\n' "${INFO_OUT[@]}" | sort -u | sed '/^$/d' | wc -l | tr -d ' ')

echo "Summary: CRITICAL(outside)=$crit_out_count, CRITICAL(tests)=$crit_test_count, INFO=$info_count" >&2

if ((${#CRIT_OUT[@]})); then
  echo "Files with CRITICAL patterns outside tests/specs:" >&2
  printf '%s\n' "${CRIT_OUT[@]}" | sort -u >&2
fi
if ((${#CRIT_TEST[@]})); then
  echo "Files with CRITICAL-like patterns in tests/specs (not failing):" >&2
  printf '%s\n' "${CRIT_TEST[@]}" | sort -u >&2
fi
if ((${#INFO_OUT[@]})); then
  echo "Files with informational patterns (not failing):" >&2
  printf '%s\n' "${INFO_OUT[@]}" | sort -u >&2
fi

exit $FAIL

