#!/usr/bin/env bash
# Verify the Shakapacker manifest in the test Docker image contains all expected entries.
# This catches stale Docker image caches where webpack assets are missing.
set -euo pipefail

MANIFEST=/app/public/packs-test/manifest.json

# --- Check prerequisites ---
if ! command -v jq &>/dev/null; then
  echo "::error::jq is not installed in the Docker image. Cannot verify Shakapacker manifest."
  exit 1
fi

if [ ! -f "$MANIFEST" ]; then
  echo "::error::Shakapacker manifest not found at $MANIFEST. The test Docker image may need rebuilding."
  exit 1
fi

# --- Validate critical entrypoints ---
# These are looked up at runtime via Shakapacker.manifest.lookup! and will crash the app if missing.
# Sources:
#   packs/  -> email.scss, design.scss, admin.scss, admin.ts, api.ts, base.ts, inertia.js, mobile_tracking.ts
#   widget/ -> embed.ts, overlay.ts, overlay.scss
CRITICAL_KEYS=(
  "email.css"
  "design.css"
  "admin.css"
  "admin.js"
  "api.js"
  "base.js"
  "inertia.js"
  "mobile_tracking.js"
  "overlay.js"
  "overlay.css"
  "embed.js"
)

MISSING=()
for key in "${CRITICAL_KEYS[@]}"; do
  if ! jq -e --arg k "$key" '.[$k]' "$MANIFEST" >/dev/null 2>&1; then
    MISSING+=("$key")
  fi
done

if [ ${#MISSING[@]} -gt 0 ]; then
  echo "::error::Shakapacker manifest is missing critical entries: ${MISSING[*]}. The test Docker image cache is likely stale — rebuild with make build_test."
  exit 1
fi

# --- Sanity-check total entry count ---
# The manifest should contain at least as many keys as we have entrypoints plus webpack runtime/commons chunks.
# A drastically low count signals a broken build even if the critical keys happen to be present.
MIN_EXPECTED=14
ACTUAL_COUNT=$(jq 'keys | length' "$MANIFEST")
if [ "$ACTUAL_COUNT" -lt "$MIN_EXPECTED" ]; then
  echo "::error::Shakapacker manifest has only $ACTUAL_COUNT entries (expected at least $MIN_EXPECTED). The build may be incomplete."
  exit 1
fi

echo "Shakapacker manifest OK — all ${#CRITICAL_KEYS[@]} critical entries present, $ACTUAL_COUNT total entries"
