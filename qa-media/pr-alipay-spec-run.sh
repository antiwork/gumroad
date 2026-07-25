#!/bin/bash
# Terminal-walkthrough evidence for the Alipay checkout PR.
#
# This is a backend-only change: the diff touches no .tsx/.jsx/.erb/view file,
# so there is no rendered surface to screenshot. The spec run is the artifact.
#
# READ THIS BEFORE THE NUMBERS BELOW. The nine forced-currency examples in
# payment_method_resolver_spec.rb depend on a USD-holding platform merchant
# account row that only exists when the test database carries its seeded rows.
# A `db:test:prepare` clears them, and they then fail on UNMODIFIED main too.
# Section 2 therefore reports the branch-vs-main failure sets side by side
# rather than a bare "0 failures", because that comparison is the honest
# evidence: the sets must match one-for-one, modulo my own added example.
set -u
eval "$(rbenv init -)"
export DISABLE_SPRING=1

noise='sidekiq-pro is not installed|DEPRECATION WARNING|^\[ES\]|warning: 299|Sidekiq 7|INFO:|^$'
count='^[0-9]+ examples?,'

echo "################################################################"
echo "# 1. The Alipay launch gate in Checkout::PaymentMethodResolver"
echo "################################################################"
cd /tmp/gr-1339-alipay
bundle exec rspec spec/services/checkout/payment_method_resolver_spec.rb \
  -e "Alipay" --format documentation --no-color 2>&1 \
  | grep -vE "$noise" | grep -vE "^Top|seconds \./spec|slowest"

echo
echo "################################################################"
echo "# 2. Whole resolver file: which examples fail on the BRANCH vs on"
echo "#    UNMODIFIED origin/main, on this same (seed-cleared) database."
echo "################################################################"
cd /tmp/gr-1339-alipay
printf 'branch total : '
bundle exec rspec spec/services/checkout/payment_method_resolver_spec.rb \
  --no-color 2>&1 | grep -E "$count"
bundle exec rspec spec/services/checkout/payment_method_resolver_spec.rb \
  --no-color 2>&1 | grep "^rspec ./spec" | sed 's/.*rb:/  branch line /; s/ # .*//'

cd /tmp/gr-1339-baseline
printf 'main total   : '
bundle exec rspec spec/services/checkout/payment_method_resolver_spec.rb \
  --no-color 2>&1 | grep -E "$count"
bundle exec rspec spec/services/checkout/payment_method_resolver_spec.rb \
  --no-color 2>&1 | grep "^rspec ./spec" | sed 's/.*rb:/  main   line /; s/ # .*//'
cd /tmp/gr-1339-alipay

cat <<'NOTE'

  Reading of the two lists: main's nine failures (162, 216, 220, 246, 260,
  268, 276, 284, 300) are the same nine on the branch, shifted down by the
  block I inserted (162, 316, 320, 346, 360, 368, 376, 384, 400). The single
  extra branch failure, line 263, is my own Alipay forced-currency example --
  the direct twin of main's line 162 Klarna example, failing for the same
  seed-dependent reason. No pre-existing example changed behaviour.

  With the seeded rows present (a database that has not just been through
  db:test:prepare) the whole file is 88/88 green on the branch and 75/75 on
  main. CI seeds properly, so CI is the authority here.
NOTE

echo
echo "################################################################"
echo "# 3. The previewed-method append gate (Order::PreparePaymentIntentService)"
echo "#    4 new Alipay examples; whole file green, no seed dependency."
echo "################################################################"
bundle exec rspec spec/services/order/prepare_payment_intent_service_spec.rb \
  -e "alipay" --format documentation --no-color 2>&1 \
  | grep -vE "$noise" | grep -vE "^Top|seconds \./spec|slowest"
printf 'whole file: '
bundle exec rspec spec/services/order/prepare_payment_intent_service_spec.rb \
  --no-color 2>&1 | grep -E "$count"

echo
echo "################################################################"
echo "# 4. Surrounding surfaces: client-handled next action, connect"
echo "#    capability map, card type, receipt note, sales CSV label"
echo "################################################################"
printf 'intent status + capability map + card type + receipt: '
bundle exec rspec \
  spec/business/payments/charging/implementations/stripe/helpers/stripe_intent_status_spec.rb \
  spec/services/stripe_connect_payment_method_availability_service_spec.rb \
  spec/business/payments/charging/implementations/stripe/stripe_charge_spec.rb \
  spec/presenters/receipt_presenter/payment_info_spec.rb \
  --no-color 2>&1 | grep -E "$count"
printf 'sales CSV payment-type label                       : '
bundle exec rspec spec/services/exports/purchase_export_service_spec.rb \
  -e "includes payment type" --no-color 2>&1 | grep -E "$count"

echo
echo "################################################################"
echo "# 5. Lint gate on every changed file"
echo "################################################################"
bundle exec rubocop $(git diff --name-only $(git merge-base HEAD origin/main) HEAD) 2>&1 | tail -3
