# Stripe FX Quotes: running live money movement on a preview API version

Buyer-currency charging (charging a buyer in their own currency instead of USD) needs an
exchange rate that is locked for long enough to show the buyer a price, let them pay it, and
settle the charge at that same rate. Stripe's FX Quotes API is what provides that lock.

FX Quotes is a **preview** API. Stripe ships preview APIs "as is", with no warranty and no
committed deprecation window, and gates access per account by merchant category code. There is
no announced general-availability date. Gumroad nevertheless charges real buyers through it at
full volume, so the risk has to be written down, owned, and bounded rather than left implicit.

## Accepted risk

Gumroad accepts the risk of running live money movement on the FX Quotes preview API, on these
terms:

- **Accountable owner:** Sahil Lavingia. Operated day to day by the Gumclaw agent, which owns
  the general-availability watch and the version-bump review described below.
- **Accepted on:** 2026-07-25, in antiwork/gumroad-private#1325 ("I'm okay with the stripe fx
  api being 'beta'").
- **What could go wrong:** Stripe changes or withdraws the preview endpoint, or changes the
  shape of a quote, without the notice a stable API would get. FX quote creation starts
  failing, or returns something the code no longer understands.
- **Why that is survivable:** every FX quote failure falls back to the canonical USD path.
  `StripeFxQuote` raises `SettlementCurrencyMismatch` or a `ChargeProcessor` error, and the
  caller charges in USD instead. A buyer sees a USD price rather than their local one; nobody
  is charged the wrong amount and no payment is lost. Buyer-currency presentment is an
  enhancement layered on a working USD checkout, not a replacement for it.
- **What is not accepted:** a silent change to which API version live charges run on. See the
  pin rules below.

## How the pin is scoped

The preview version is applied **per request**, never globally:

- `StripeFxQuote::API_VERSION` (`app/business/payments/charging/implementations/stripe/stripe_fx_quote.rb`)
  is the single source of truth for the pinned preview version.
- The global `Stripe.api_version` set in `config/initializers/003_stripe.rb` is a stable
  version and carries no preview train. Every Stripe call Gumroad makes — payouts, refunds,
  account onboarding, tax forms — runs on that stable version.
- Exactly three call sites send the preview version, and only when a buyer-currency quote is
  actually in play: creating the quote itself, and the two PaymentIntent paths
  (`StripeDeferredPaymentIntent`, `StripeChargeProcessor`) that attach an existing
  `fx_quote` id. With no quote id there is no version override, so a plain USD charge is
  untouched by the preview surface.

`spec/business/payments/charging/implementations/stripe/fx_quote_preview_pin_spec.rb` pins all
of that: it fails if the pinned version stops being a preview version, if the global version
starts carrying a preview train, or if either PaymentIntent path starts sending the preview
version on charges that have no FX quote.

## Rules that keep the pin deliberate

1. **A version bump is a reviewed change.** Changing `StripeFxQuote::API_VERSION` is a code
   change in its own pull request, reviewed like any other payments change, with the diff of
   Stripe's changelog between the two versions summarised in the PR body. It is never bundled
   into unrelated work and never done to "get onto the latest preview".
2. **Never bump the global version to a preview train.** If a future feature needs a preview
   API, it gets its own scoped per-request override, the same way FX Quotes does.
3. **Watch for general availability and leave preview when it lands.** A recurring
   `stripe-fx-quote-ga-watch` job polls Stripe's changelog for an FX Quotes
   general-availability entry and reports when one appears. On that signal: move the FX quote
   and presentment PaymentIntent calls onto the stable version, delete the per-request
   override, and delete this document's accepted-risk section along with the watch.

## If the preview endpoint breaks

The symptom is a rise in `ChargeProcessorFxQuoteInvalidError` or `SettlementCurrencyMismatch`,
with buyer-currency checkouts falling back to USD. The immediate mitigation is to turn the
buyer-currency feature flag off, which stops quote creation entirely and puts every buyer back
on the USD path; then fix forward against whatever Stripe changed.
