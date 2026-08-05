# Domain lens: checkout/payment-element revert (PR #7079)

This branch reverts #7019 and #7070 (CardElement-fallback removal + partial restore), then
re-applies the `stripe_error` strong-params hash permit on top. Focus checks:

1. **Revert completeness vs pre-#7019 baseline.** Confirm the reverted tree matches
   `5ede7b990~1` exactly except for the two stated deliberate residuals (`stripe_error` hash
   permit; `order.test.ts` uid-keyed fixtures from #7063). Any other drift is a finding.
2. **SCA / 3DS / Indian e-mandate confirm paths** — these are the specific flows #7019 broke.
   Verify the reverted code restores the CardElement-based confirm flow correctly and that no
   residual Payment-Element-only code path remains half-wired (dead imports, orphaned reducer
   cases, a component expecting a prop the reverted flow no longer passes).
3. **`stripe_error` strong-params fix**: is `permitted_order_params` now accepting the hash shape
   the client actually sends? Check for over-permissive param whitelisting (does it accept
   arbitrary nested keys under `stripe_error`, and is that a problem for anything downstream that
   trusts the fields, e.g. logging/display of `decline_code`/`message`)?
4. **Test coverage**: the PR body lists 4 previously-red spec files with UNCHECKED checkboxes —
   were they actually run and did they pass? Treat unchecked boxes as unverified until proven.
5. **Money-path regression risk**: any live purchase/subscription/membership checkout flow that
   depends on the removed Payment-Element-only code paths (upsells, offer codes, installment
   plans, tiered membership) — enumerate from the diff's spec file list and confirm each still
   passes under the reverted implementation.
6. **QA screenshots removed** (`qa-media/pr-7019-*`, `qa-media/pr-7070-*`) — confirm this is
   intentional cleanup (evidence of removed PRs) and not a sign real functionality regressed
   silently in this revert.
