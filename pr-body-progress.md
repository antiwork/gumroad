## What / why

Give US businesses separate single-member and multi-member LLC choices and map their declared type to Stripe's US structures. Create/update use the legal-entity country; no member count is inferred for legacy `llc` rows.

Unsupported saved types now show `Type` and cannot save: the dropdown and save validation share the active list. This closes Greptile's P1; the previous appended-legacy-option fix preserved the label but still allowed the invalid save. The two redundant comments were shortened/removed.

## Before / after

Current-head desktop/mobile light/dark captures are complete. Origin/main before captures are rebuilding after invalidating stale Typia output; attachments will be added before handoff. Do not merge yet.

## QA / test results

- [x] On Settings → Payments, a US business saved as `llc` sees `Type`. Update settings marks it invalid using the existing required-fields banner; selecting either LLC member count permits the valid form to submit. Other countries keep their own/generic options.
- [x] Vitest: both payments files, 20 tests passed. Rendering-only revert: 2/9 fail; save-validation-only revert: 1/11 fails. Restored code passes 20/20.
- [x] RSpec: `stripe_merchant_account_manager_spec.rb -e 'US company structure' -e 'company hash keyed on the Stripe account country'`: 19 examples, 0 failures.
- [x] TypeScript, ESLint on changed components, Prettier, and RuboCop on changed Ruby files pass. Regenerated worktree js-routes before typechecking.
- [ ] Full CI at this head: running (run-all-specs enabled).

## Scope / handoff

AE reach is deliberately unchanged; its evidence-backed decision is recorded on antiwork/gumroad-private#2609. Non-profit structures remain out of scope. No production writes or seller email.

Gianfranco owns human review and merge after CI; no auto-merge. Refs antiwork/gumroad-private#2609.

Premerge review: clean @ 2450f08d24207ef6748d2df38003a3c80c4ba115

---
AI disclosure: Astra (gpt-6-astra), via Hermes; instructed to finish #2609, address Greptile, capture before/after, decide AE reach using Stripe documentation and read-only production counts, and leave the merge to Gianfranco.
