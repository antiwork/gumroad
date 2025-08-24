#!/usr/bin/env bash
set -euo pipefail

# Usage:
#   ./scripts/run_product_editor_matrix.sh
#
# Runs the product editor focused specs across common env combinations.
# Assumes you can run bundle exec rspec in your environment.

FOCUSED_FILES=(
  "spec/requests/products/edit/edit_spec.rb:591"
  "spec/requests/products/edit/rich_text_editor_spec.rb:289"
)

run_case() {
  local title="$1"; shift
  echo
  echo "====================================="
  echo "CASE: $title"
  echo "====================================="
  echo "Command: $* bundle exec rspec ${FOCUSED_FILES[*]} --format documentation --force-color --no-profile"
  echo
  env "$@" bundle exec rspec "${FOCUSED_FILES[@]}" --format documentation --force-color --no-profile || true
}

# Baseline: bypass nav fragility
run_case "Baseline (bypass account switch UI)" DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test

# SSR on: exercise SSR path
run_case "SSR ON (Product Editor + global)" REACT_ON_RAILS_PRERENDER=true DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test

# Flag off: disable save shortcut and aria-keyshortcuts
run_case "Shortcut Flag OFF" PRODUCT_EDITOR_SAVE_SHORTCUT=false DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test

# SSR on + Flag off
run_case "SSR ON + Shortcut Flag OFF" REACT_ON_RAILS_PRERENDER=true PRODUCT_EDITOR_SAVE_SHORTCUT=false DISABLE_ACCOUNT_SWITCH_UI=true RAILS_ENV=test

