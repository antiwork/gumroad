# Domain lens: UPI on USD checkouts + buyer-currency widening (gumroad#7385)

Money path. Review `origin/main...HEAD` adversarially. Do not run the suite. Do not modify files.
Verdict must be READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.

This is a ROUND-2+ review of a moved head. Prior panel at `77812e9b` found two P1s; prior panels
at `67ff2577`/`d8501b95`/`3dbea9c` found a displayed-quote vs prepare-mint P0 that later commits
claimed to fix. Grade each prior finding RESOLVED / STILL-OPEN / REGRESSED with file:line.

## Prior findings to re-grade

1. **Displayed FX quote must bind prepare** (P0, payment.ts / method_forced_presentment.rb).
   Client remounts on `display.chargePresentmentTotalCents`; prepare must reuse that exact quote
   token, fail closed if missing/invalid, and not mint a second rate. A USD-mounted client-confirm
   must still reject an unexpected quote.
2. **Sign the INR remount method list** (P1, stripe_payment_presenter.rb). USD `payment_method_types`
   excludes `upi`; the browser later mounts `payment_method_types + inr_local_methods`. If the signed
   token still covers only the USD list, prepare has no signed authorization for UPI.
3. **Display-opt-out quote exception must not be a general GeoIP override** (P1, buyer_currency_quote.rb).
   HEAD commit `7388855a` claims to offer buyer currency on EVERY checkout, not only USD-UPI remounts.
   That is a deliberate widening — attack it as an eligibility-predicate widening, not assume it is
   the requested fix for finding 3.

## Numbered checklist

1. **Money-repricing sweep.** `buyer_currency_eligibility` / `buyer_currency_quote` / forced
   presentment now apply more broadly. Walk every call site in app/lib. Does any path set a PRICE
   or move MONEY (prepare PaymentIntent, subscription renew, native/in-app, mobile)? Display path
   and charge path must resolve the same currency+amount. A widened quote with a USD element (or
   the inverse) is shown-one-charged-another.
2. **Product of independent flags.** Local-currency display opt-out, GeoIP country, product
   listing currency, `inr_local_methods` / UPI remount, Flipper `checkout_local_method_upi`,
   membership vs one-shot cart. Ask for the truth table. Both-true must not land in the first
   branch with a blocker the buyer cannot clear.
3. **Fail-closed vs fail-open.** Missing quote token, expired quote, ConfirmationToken currency
   ≠ intent currency, UPI token against a USD intent, iDEAL/Pix siblings. Which errors are
   infra (fail open) vs invalid input (fail closed)? Can a visitor induce the infra path?
4. **Signed contract vs client-assembled method list.** Whatever the Element actually mounts
   must be what prepare is allowed to put on the PaymentIntent. Unsigned client-reported
   `reported_element_mount_currency` is attacker-controlled.
5. **Rollout-window / in-flight.** Clients mid-checkout still send the old payload (no quote
   token, no buyer_currency_quote). Does prepare fail closed on those, or silently mint?
6. **Sibling local methods (iDEAL, Pix, etc.).** If the root cause is "local method + USD listing",
   enumerate every launched local method. N-of-M coverage is a merge blocker unless the code
   deliberately scopes to UPI and the copy/flag/docs match.
7. **Settings copy** (`Settings/Payments/Show.tsx`): route reality, role reachability, whether
   the new sentence overclaims where buyer currency now applies.
8. **Specs load-bearing?** Name any new example that would still pass if the production change
   were reverted, or that stubs Stripe so it cannot witness a quote-identity mismatch.
9. **Reachability.** Is the new path live behind a flag that is off in prod? Gate the new
   behaviour, not a correctness fix underneath a dead path.

Hard constraints: static review only; no test suite; no file writes; full verdict in the final
message. Do not defer.
