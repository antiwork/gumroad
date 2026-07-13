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
