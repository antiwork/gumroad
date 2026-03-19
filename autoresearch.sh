#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

eval "$(rbenv init -)" 2>/dev/null || true
rbenv shell 3.4.3 2>/dev/null || true

# Pre-check: syntax validation of changed spec files
CHANGED_FILES=$(git diff --name-only HEAD~1 2>/dev/null || echo "")
SYNTAX_OK=true
for f in $CHANGED_FILES; do
  if [[ "$f" == *.rb ]] && [[ -f "$f" ]]; then
    if ! ruby -c "$f" > /dev/null 2>&1; then
      echo "SYNTAX ERROR in $f"
      ruby -c "$f" 2>&1
      SYNTAX_OK=false
    fi
  fi
done

if [[ "$SYNTAX_OK" != "true" ]]; then
  echo "METRIC flaky_test_count=999"
  exit 1
fi

# Count known flaky patterns
FLAKY=0

# 1. payments_spec.rb: Count tests that visit settings_payments_path and click "Update settings"
#    without any Stripe stubbing/mocking (they hit real Stripe API → rate limited)
#    We count "allows to enter bank account details" tests as these are the country-specific ones
PAYMENTS_COUNTRY_TESTS=$(grep -c 'it "allows to enter bank account details"' spec/requests/settings/payments_spec.rb || true)
PAYMENTS_COUNTRY_TESTS=${PAYMENTS_COUNTRY_TESTS:-0}
# Check if there's a Stripe account creation stub/mock in the before block
PAYMENTS_STUBBED=$(grep -c 'stub_stripe_account_creation\|mock_stripe_account\|allow.*Stripe::Account.*create\|vcr.*cassette.*payments' spec/requests/settings/payments_spec.rb || true)
PAYMENTS_STUBBED=${PAYMENTS_STUBBED:-0}
if [[ $PAYMENTS_STUBBED -eq 0 ]]; then
  FLAKY=$((FLAKY + PAYMENTS_COUNTRY_TESTS))
fi

# 2. taxes_spec.rb: Count check_out calls without a block (no wait_for_ajax)
#    that also use country-specific credit cards (international tax tests)
TAXES_CHECKOUT_NO_BLOCK=$(grep -c 'check_out.*credit_card.*number.*[^)]$' spec/requests/purchases/product/taxes_spec.rb || true)
TAXES_CHECKOUT_NO_BLOCK=${TAXES_CHECKOUT_NO_BLOCK:-0}
FLAKY=$((FLAKY + TAXES_CHECKOUT_NO_BLOCK))

# 3. Other known flaky patterns: count specific fragile assertions
# shipping_physical_preorder_spec.rb — timing issue with tax calculation
PREORDER_FLAKY=$(grep -c 'charges the proper amount with taxes for preorder' spec/requests/purchases/product/shipping/shipping_physical_preorder_spec.rb || true)
PREORDER_FLAKY=${PREORDER_FLAKY:-0}
FLAKY=$((FLAKY + PREORDER_FLAKY))

echo "payments_unstubbed=$PAYMENTS_COUNTRY_TESTS taxes_no_block=$TAXES_CHECKOUT_NO_BLOCK preorder=$PREORDER_FLAKY"
echo "METRIC flaky_test_count=$FLAKY"
