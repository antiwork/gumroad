# Presentment refund views (PR #5846) — implementation notes

Branch: `presentment-refund-views` off main (scaffold 613b16b57).

## Plan
1. `Refund` model: helpers to read/format the buyer-currency (presentment) snapshot.
2. `CustomerMailer#refund` / `#partial_refund`: optional `refund_id` param threaded from
   `Purchase::Refundable` callers; views show presentment amount with canonical USD alongside
   when the snapshot exists, byte-identical fallback otherwise.
3. Mailer previews for both variants.
4. Admin purchase presenter + `Admin/Purchases/index.tsx`: presentment beside Transaction Total
   and per-refund amount rows, gated on presentment data existing.
5. Specs: mailer + presenter (fail-on-revert). No `*.test.tsx` pattern exists anywhere in the
   repo (no @testing-library/react in package.json), so admin UI coverage lives in presenter
   specs; component change kept to display-only gating.

## Decisions
- Threaded `refund_id` as a trailing OPTIONAL mailer param (backward compatible with queued
  Sidekiq jobs serialized before the deploy). Callers in `app/modules/purchase/refundable.rb`
  pass `refund.id` / `refund&.id` — the refund is saved (via `refunds << refund` on a persisted
  purchase) before the mailer call, so the id exists.
- Formatting uses `MoneyFormatter.format(cents, currency.to_sym, no_cents_if_whole: true,
  symbol: true)` — same as `Purchase#format_buyer_presentment_amount`, so non-100-subunit
  currencies (JPY/KRW) are handled by the shared helper, never hand-divided.
- Full-refund email: primary figure = the refund snapshot amount (buyer currency), canonical
  `formatted_total_transaction_amount` in parens.
- Partial-refund email: refund amount = snapshot amount + USD in parens; purchase total shows
  presentment total + USD in parens when `purchase_presentment` exists.
- Admin refund rows: an "Amount:" line is added ONLY when the refund carries a presentment
  snapshot (old refunds render exactly as today). Purchase-level presentment total is appended
  in parens after the canonical Transaction Total only when `purchase_presentment` exists.

## Progress log
- [x] Scouted mailers/views/presenter/component/factories.
- [x] Slice 1 (mailers): `Refund#presentment_snapshot?` / `#formatted_presentment_amount`,
  `CustomerMailer#refund`/`#partial_refund` take optional trailing `refund_id`, both callers in
  `Purchase::Refundable` pass it, views render buyer currency + "(… USD)" only when the snapshot
  exists. Previews: `refund_presentment` / `partial_refund` / `partial_refund_presentment` added.
  Safety guard: the mailer ignores a `refund_id` whose refund belongs to a different purchase.
  Specs: `spec/mailers/customer_mailer_spec.rb` — 7 examples, 0 failures (snapshot, no-snapshot
  exact-fallback with `not_to include("USD)")` revert guard, mismatched-refund).
  Formatting note: `MoneyFormatter` renders CAD as `CAD$28.83` (not `CA$`).
- [x] Slice 2 (admin): presenter adds `formatted_presentment_total` (purchase level, from
  `Purchase#formatted_buyer_presentment_total`) and per-refund `formatted_presentment_amount` +
  `formatted_usd_amount` (USD figure only emitted when a snapshot exists, so old rows stay
  unchanged). Component types + rendering: Transaction Total gets "(CAD$13.50)" suffix; refund
  rows get an "Amount: $10 (CAD$14.30)" line only when snapshot data exists. Specs:
  `spec/presenters/admin/purchase_presenter_spec.rb` — 12 examples, 0 failures.
  No `*.test.tsx` exists anywhere in `app/javascript` (no @testing-library), so there is no
  component-test pattern to follow — admin coverage lives in the presenter spec; component
  change is display-only null-gated rendering. `npx tsc --noEmit` reports only a pre-existing
  environment error (`Cannot find type definition file for 'vite/client'` via symlinked
  node_modules); the LSP confirmed no new type errors in the edited component.
- Test env notes: worktree needed `node_modules` and `public/vite-test` symlinked from
  `~/code/gumroad` (Vite manifest missing otherwise → every mailer spec fails on email.ts).
- [x] Fail-on-revert verified: with app code reverted to the scaffold commit, the new mailer
  examples (4) and presenter examples (2) fail; restored code turns them green.
- [x] Existing callers' specs updated: `spec/models/purchase/purchase_refunds_spec.rb` mailer
  argument expectations now include the refund id (`an_instance_of(Integer)`); targeted runs of
  those 2 examples + `purchases_controller_spec.rb:319` green.
- [x] Rubocop clean on all touched Ruby files. Pushed as 3 commits (…→97205c91f).
- Not done: vitest component test — the repo has zero *.test.tsx files and no React testing
  library; admin UI logic is null-gated display covered via presenter specs instead.
- [x] Greptile P1 fix: amounts labeled "USD" in the refund emails were formatted in the
  product/display currency (wrong for non-USD products). The mailers now format the USD
  figures explicitly (`formatted_price("usd", …)`); new specs cover a EUR-display product.
