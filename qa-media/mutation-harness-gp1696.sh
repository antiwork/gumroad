#!/bin/bash
# Mutation harness: each mutation removes one half of the fix; the named spec must redden.
# Run from a gumroad checkout with a working test DB, e.g.
#   DATABASE_NAME=lane0_test REDIS_HOST="localhost:6380/0" ./qa-media/mutation-harness-gp1696.sh
set -u
cd "$(git rev-parse --show-toplevel)" || exit 1
export DISABLE_SPRING=1 OBJC_DISABLE_INITIALIZE_FORK_SAFETY=YES \
  VITE_RUBY_AUTO_BUILD=false PATH="$HOME/.rbenv/shims:$PATH"

CTRL=app/controllers/bundles/product_controller.rb
SPEC=spec/controllers/bundles/product_controller_spec.rb
cp "$CTRL" /tmp/ctrl.orig

run() { ./bin/bundle exec rspec "$SPEC" --no-profile 2>&1 | grep -E "^[0-9]+ examples"; }

echo "=== BASELINE (unmutated) ==="
run

echo
echo "=== MUTATION 1: assign currency AFTER price (revert the ordering) ==="
python3 - <<'PY'
p="app/controllers/bundles/product_controller.rb"
s=open(p).read()
old="""        carried_price_cents = product_permitted_params[:price_cents].presence || @bundle.price_cents
        @bundle.price_currency_type = product_permitted_params[:price_currency_type]
        @bundle.price_cents = carried_price_cents if carried_price_cents.present?"""
new="""        carried_price_cents = product_permitted_params[:price_cents].presence || @bundle.price_cents
        @bundle.price_cents = carried_price_cents if carried_price_cents.present?
        @bundle.price_currency_type = product_permitted_params[:price_currency_type]"""
assert old in s, "MUT1 anchor missing"
open(p,"w").write(s.replace(old,new))
print("MUT1 applied")
PY
run
cp /tmp/ctrl.orig "$CTRL"

echo
echo "=== MUTATION 2: drop the carry-across (no explicit price_cents write) ==="
python3 - <<'PY'
p="app/controllers/bundles/product_controller.rb"
s=open(p).read()
old="""        carried_price_cents = product_permitted_params[:price_cents].presence || @bundle.price_cents
        @bundle.price_currency_type = product_permitted_params[:price_currency_type]
        @bundle.price_cents = carried_price_cents if carried_price_cents.present?"""
new="""        @bundle.price_currency_type = product_permitted_params[:price_currency_type]"""
assert old in s, "MUT2 anchor missing"
open(p,"w").write(s.replace(old,new))
print("MUT2 applied")
PY
run
cp /tmp/ctrl.orig "$CTRL"

echo
echo "=== MUTATION 3: drop :price_currency_type from the permit list ==="
python3 - <<'PY'
p="app/controllers/bundles/product_controller.rb"
s=open(p).read()
old="        :price_currency_type,\n"
assert old in s, "MUT3 anchor missing"
open(p,"w").write(s.replace(old,"",1))
print("MUT3 applied")
PY
run
cp /tmp/ctrl.orig "$CTRL"

echo
echo "=== MUTATION 4: drop the stale-offer-code warning ==="
python3 - <<'PY'
p="app/controllers/bundles/product_controller.rb"
s=open(p).read()
old="""    if currency_before != @bundle.price_currency_type"""
new="""    if false"""
assert old in s, "MUT4 anchor missing"
open(p,"w").write(s.replace(old,new,1))
print("MUT4 applied")
PY
run
cp /tmp/ctrl.orig "$CTRL"

echo
echo "=== RESTORED — verify clean ==="
git diff --stat "$CTRL"
run
