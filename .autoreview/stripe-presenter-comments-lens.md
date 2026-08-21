# Domain lens: comments-only trim of Checkout::StripePaymentPresenter

This diff claims to TRIM comments in `app/presenters/checkout/stripe_payment_presenter.rb`
with ZERO behaviour change. It sits on the Stripe checkout money path (quote vs
client-confirm, PWYW-at-load, Klarna quantity, selected-tier PWYW, stale membership
`customizable_price`). Review the CLAIMS, not the word count.

Numbered checks:

1. **Zero non-comment executable change.** Prove it:
   `git diff origin/main...HEAD -U0 -- app | grep -E '^[+-]' | grep -vE '^(\+\+\+|---)' | grep -vE '^[+-]\s*#' | grep -vE '^[+-]\s*$'`
   Any surviving `+/-` line that is not a comment or blank is a P0/P1: this PR is not
   comments-only and the commit message is false.

2. **Every remaining comment is still TRUE after shortening.** Instantiate each quantified
   sentence at EVERY member of the set it covers (boundary words: exactly, lands on, ANDed,
   before, only, never, always, wins). A rewrite that swaps one false claim for another is
   disqualifying. Grade what the rewrite DROPPED: dropping a SCOPE qualifier on a boundary
   fact is P1; dropping vendor history / restated code is correct under origin/main AGENTS.md
   (write for maintainers who already know the code; ≤3 lines; no vendor history).

3. **Quote vs client-confirm ordering.** The shortened block says server-confirm must come
   BEFORE client-confirm because `Prepare#block_unexpected_buyer_currency_quote` fails closed
   on a token. Verify against the live method order AND against
   `Order::PreparePaymentIntentService`. If the comment now understates the overlap case
   (quote candidate + method-forced EUR listing / CAD buyer) or the unquoted USD-GeoIP
   candidate taking this branch, say so.

4. **PWYW-at-load zero total.** Remaining comment: client-confirm would freeze
   `presentment_amount_cents` at 0 and a Klarna-less method set that later mismatches the
   deferred intent. Verify `price_still_pending?` and `fallback_reason_for` still match that
   claim. Dropping "browser prefers a non-null server amount" would be a lost trap — it is
   still in the trim; confirm it is still accurate by grepping `getStripePaymentElementAmount`.

5. **Klarna quantity.** `cart_total_usd_cents` uses `price_cents * quantity`. Comment says
   100 × $50 must be 5000 or Klarna mounts on carts Stripe will reject; Prepare re-checks;
   USD only. Verify the resolver actually uses this field as the Klarna window input, and
   that forced-currency carts never offer Klarna.

6. **Selected-tier PWYW vs product-wide scan.** `cart_line_buyer_can_name_price?` /
   `buyer_can_name_price?`: has_customizable_price_option? scans every alive tier; membership
   `customizable_price` can be stale-true. The trim dropped the "unrecognized option id →
   known so min/free checks still run" detail from one method and kept it on the other —
   confirm BOTH methods still implement that, and that the comments do not disagree.

7. **Wallet flag AND.** `BUYER_CURRENCY_WALLETS_FEATURE_NAME` comment says ANDed with
   PAYMENT_ELEMENT_WALLETS and names owned by BuyerCurrencyEligibility. Verify
   `buyer_currency_wallets?` still delegates to `wallets_enabled?` which actually ANDs both
   flags — a comment claiming AND when the helper only checks one flag is P1.

8. **flat_payment_methods?** Exception: wallets possible but payment_element_wallets off
   keeps legacy layout so Payment Request Button still renders. Verify the boolean
   `payment_element_wallets? || disable_wallets` still implements that, and that the
   shortened comment does not claim the exception for a case the code does not handle.

9. **Do not rubber-stamp "comments only".** A READY-TO-MERGE must list which claims you
   traced and found TRUE with file:line. A bare "looks fine" is the failure this gate exists
   to prevent.
