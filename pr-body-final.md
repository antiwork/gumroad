## What / why

Give US businesses separate single-member and multi-member LLC choices and map their declared type to Stripe's US structures. Create/update use the legal-entity country; no member count is inferred for legacy `llc` rows.

Unsupported saved types now show `Type` and cannot save: the dropdown and save validation share the active list. This closes Greptile's P1; the previous appended-legacy-option fix preserved the label but still allowed the invalid save. The two redundant comments were shortened/removed.

## Before / after

Real Rails + Chromium captures with a synthetic seller, desktop (1440px) and mobile (375px), light and dark. Before is `origin/main` at `0bd3d516c13`; after was recaptured at this head following the main sync. Legacy US `llc` is shown before, unselected after, then explicitly reselected as `LLC (multi-member)`.

<details><summary>Desktop / light</summary>

| Before | Reselection required | After choosing member count |
|---|---|---|
| ![before desktop light](https://github.com/user-attachments/assets/71cb98a7-1236-4d48-9bfa-8b8c8bcfad1e) | ![after desktop light](https://github.com/user-attachments/assets/d0f09de0-0c95-4671-9d51-de08fcfc737e) | ![after-selected desktop light](https://github.com/user-attachments/assets/58522304-596d-4cde-a148-d0ad30016ea8) |

</details>

<details><summary>Desktop / dark</summary>

| Before | Reselection required | After choosing member count |
|---|---|---|
| ![before desktop dark](https://github.com/user-attachments/assets/c50f6632-112a-4ade-a600-a1319316f987) | ![after desktop dark](https://github.com/user-attachments/assets/90ab0a81-58be-4736-ac6d-fd83daed2942) | ![after-selected desktop dark](https://github.com/user-attachments/assets/a4459219-8154-46c4-a521-baa375e33520) |

</details>

<details><summary>Mobile / light</summary>

| Before | Reselection required | After choosing member count |
|---|---|---|
| ![before mobile light](https://github.com/user-attachments/assets/94dd1ec3-87fb-4927-8ab4-1eae88e1996d) | ![after mobile light](https://github.com/user-attachments/assets/dd1cd9cd-82ed-43d3-9845-87d585afccb6) | ![after-selected mobile light](https://github.com/user-attachments/assets/1cc06282-6129-45ce-9af5-a82cc3c12c9a) |

</details>

<details><summary>Mobile / dark</summary>

| Before | Reselection required | After choosing member count |
|---|---|---|
| ![before mobile dark](https://github.com/user-attachments/assets/02e74b2a-2362-4596-97ed-ccfce527f87e) | ![after mobile dark](https://github.com/user-attachments/assets/5599d158-4d79-4885-902f-c0186e247ce1) | ![after-selected mobile dark](https://github.com/user-attachments/assets/83ea83a4-c3f7-4de3-85e3-e25ca6c1295f) |

</details>

Captured-state walkthrough (slideshow of the real screenshots, not a real-time recording):

https://github.com/user-attachments/assets/3c7d0da1-2c32-453a-bd96-9b406de9603e

## QA / test results

- [x] On Settings → Payments, a US business saved as `llc` sees `Type`. Update settings marks it invalid using the existing required-fields banner; selecting either LLC member count permits the valid form to submit. Other countries keep their own/generic options.
- [x] Vitest: both payments files, 22 tests passed after main sync. Earlier guard revert proofs: rendering-only 2/9 fail; save-validation-only 1/11 fails; restored code passed 20/20 before main added two bank-code tests.
- [x] RSpec: `stripe_merchant_account_manager_spec.rb -e 'US company structure' -e 'company hash keyed on the Stripe account country'`: 19 examples, 0 failures.
- [x] Browser RSpec: saved-EIN edit and legacy LLC reselection → 2 examples, 0 failures. The stale generic-LLC fixture behind Slow 42 was updated; the negative case explicitly verifies that no business type is changed until the seller selects it.
- [x] TypeScript, ESLint on changed components, Prettier, and RuboCop on changed Ruby files pass. Regenerated worktree js-routes before typechecking.
- [x] Full CI at `37dfec6b0998c5c87ad0c77b63bdf75cfbd3af8a`: 81 successful checks, 17 skipped, none pending or failed (run-all-specs enabled).

Broad local `test-confidence` was stopped during full merge-base replay after its earlier baseline failures; no 99% verdict is claimed. The direct suites above and full exact-head CI are the verification evidence.

## Scope / handoff

AE reach is deliberately unchanged; its evidence-backed decision is recorded on antiwork/gumroad-private#2609. Non-profit structures remain out of scope. No production writes or seller email.

Synced main and preserved both Egyptian bank-code tests and the US business-type tests. Gianfranco owns human review and merge after CI; auto-merge is disabled.

Closes antiwork/gumroad-private#2609

Premerge review: clean @ 37dfec6b0998c5c87ad0c77b63bdf75cfbd3af8a

---
AI disclosure: Astra (gpt-6-astra), via Hermes; instructed to finish #2609, address Greptile, capture before/after, decide AE reach using Stripe documentation and read-only production counts, and leave the merge to Gianfranco.
