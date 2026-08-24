## What

Allow the checkout currency selector to keep a product's own listed currency available when the direct-listed lane can charge that cart.

This covers gumroad-private#2190 gap 1: listed-currency == buyer-currency was being removed from `available_buyer_currencies` because the FX quote lane correctly returns no quote for that all-listed shape. The selector now treats that nil quote as expected only when the direct-listed gates accept the cart.

## Why

For an eligible CAD-listed product with a Canadian card buyer (same shape as the INR listing + Indian buyer case), checkout should offer CAD instead of falling back to a USD-only selector. The direct-listed lane charges the listed amount without an FX quote, so the surcharge endpoint has to preserve that currency option rather than applying the quote-lane rejection rule.

## Before / After

Before:
- A cart uniformly listed in the buyer's currency produced no FX quote, then the surcharge endpoint removed that requested currency from the selector options.
- Buyers only saw USD even when the direct-listed card lane was ramped and able to charge the listed currency.

After:
- `Checkout::BuyerCurrencyEligibility.direct_listed_line_items_eligible?` mirrors the direct-listed cart gates for surcharge line items.
- `CustomerSurchargeController` keeps a nil-quote listed currency in the selector only when that helper accepts the cart.
- The selector still hides the listed currency when the direct-listed flag is off or the cart has a rejected shape like a tip.

## Test Results

- `ruby -c app/controllers/customer_surcharge_controller.rb`
- `ruby -c app/services/checkout/buyer_currency_eligibility.rb`
- `DISABLE_SPRING=1 bundle exec rspec spec/controllers/customer_surcharge_controller_spec.rb` — 40 examples, 0 failures
- `DISABLE_SPRING=1 bundle exec rspec spec/services/checkout/buyer_currency_eligibility_spec.rb spec/services/checkout/buyer_currency_quote_spec.rb:811 spec/services/checkout/buyer_currency_quote_spec.rb:823` — 100 examples, 0 failures
- Local autoreview, Codex leg — clean, no P0/P1 findings
- Full panel review — still owed because one reviewer leg is unavailable in this session

## QA steps

- Preview/browser QA is still owed after the draft PR is open and its preview app is available.
- Planned QA: open a preview checkout for a direct-listed-ramped same-currency product, verify the selector includes the listed currency, and verify an ineligible tipped listed-currency cart does not keep that option.

## Status

- [x] Scope — build gumroad-private#2190 gap 1 selector eligibility only; tips and flag ramp remain separate work items.
- [x] Design — reuse direct-listed eligibility gates rather than treating nil quote as a generic failure.
- [x] Build — backend selector options updated with regression specs.
- [ ] Ship — draft only; money-path PR, not ready for human review. Preview/browser selector proof and full panel review remain owed.
- [ ] Market
- [ ] Sell

Related: antiwork/gumroad-private#2190