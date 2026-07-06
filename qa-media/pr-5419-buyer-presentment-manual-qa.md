# Buyer-presentment manual QA plan

Issue: https://github.com/antiwork/gumroad/issues/5419
Session: `gumclaw/2026-07-02-presentment-webhook-manual-qa`

This file exists so the next PR has a durable manual QA checklist for preview testing already-merged buyer-presentment work. Keep GitHub as the source of truth: post results/evidence back to the PR and #5419 ledger.

## Preview setup

- Use the PR preview app.
- Staging seller: `seller@gumroad.com` / actor `User;5651668063099`.
- Enable `buyer_local_currency` and `buyer_currency_charging` for the seller on preview.
- Simulate Canada with `X-Forwarded-For` / `CF-Connecting-IP` (for example `24.48.0.1`) or a proxy.

## QA debt carried into this PR

### #5627 purchase path

- [ ] CAD buyer sees CAD presentment display.
- [ ] FX quote locks the checkout total.
- [ ] Stripe PaymentIntent uses CAD amount/currency and an FX quote.
- [ ] `charge_presentments` and `purchase_presentments` persist.
- [ ] Buyer receipt/confirmation show CAD.
- [ ] Seller/accounting surfaces stay USD.

### #5687 seller/admin refund path

- [ ] Full refund sends the CAD presentment amount to Stripe.
- [ ] Partial refund sends proportional CAD.
- [ ] Final refund takes exact remaining CAD cents.
- [ ] `refunds.json_data` stores the presentment snapshot.
- [ ] Seller/affiliate balance debits stay canonical USD.
- [ ] Gumroad-tax-only refund still fails closed.

### #5689 processor/webhook refund path

- [ ] Processor-initiated CAD refund derives canonical refund rows.
- [ ] Webhook matching compares against presentment snapshot, not canonical USD.
- [ ] Non-presentment-currency flow of funds fails closed.

### Fallbacks

- [ ] US buyer stays USD.
- [ ] Flags off means canonical behavior and no presentment rows.
- [ ] Display-only local-currency surface still renders.
