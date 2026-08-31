Don't revert a seller's pay-what-you-want toggle on an unchanged editor save

## What

PR #7450 stopped the editor clearing a seller's **custom URL** on a later save, but the **pay-what-you-want** flag (`customizable_price`) had the same defect and #7450's guard did not cover it: the editor posts the whole product snapshot on every save and always sends `customizable_price` as a **boolean** (never nil), so the `nil`-branch #7450 added could never fire on the editor path. A later save of another section — from a stale tab whose snapshot predates the toggle, or simply an unchanged form state — sent `customizable_price: false` and silently turned PWYW off.

This extends `scalarSettingsForSave` to treat `customizable_price` the same way it already treats `custom_permalink`: **only send it when this session deliberately changed it** relative to the last-saved value. An unchanged snapshot omits it; a real toggle-off (or toggle-on) this session still sends the value.

## Why

gumroad-private#2348 — a seller's custom URL and PWYW toggle were both being reset on later saves of the same draft product. PaperTrail showed each scalar was set and persisted, then a later save of the description/content section reverted both. #7450 fixed the URL half; this fixes the toggle half. This is the same scalar-`links`-attributes surface, distinct from the collection-deletion guards of #1379.

Consistency with the backend guard is preserved: `Product::Prices#set_customizable_price` and the frontend `reconcileCustomizablePrice` still force the flag on/off for a $0-base plus paid-variant case on every state write, so omitting an unchanged value is safe — the force is re-applied at save time anyway.

## Before / after

- **Before:** a later editor save whose snapshot carries `customizable_price: false` writes `false` over a seller-set `true`, even when the seller did not touch the toggle on this save. (Editor always sends a boolean, so the #7450 `nil`-branch never intercepted it.)
- **After:** an unchanged `customizable_price` is omitted from the payload; only a deliberate change this session is sent. A seller who toggles PWYW off still sends `false`.

## Checklist

- [x] Scope — only the editor save payload's `customizable_price` omission; does not touch the $0-base + paid-variant force (already handled by `reconcileCustomizablePrice` / `set_customizable_price`).
- [x] Design — mirror #7450's `scalarSettingsForSave` shape: omit unchanged scalar, send deliberate changes.
- [x] Build — `gumclaw/gp2348-pwyw-toggle-save` @ `2fbbc719b`
- [x] QA — focused vitest cases (existing permalink cases preserved + 2 new PWYW cases), mutation proof (new PWYW test reddens on always-send), ProductEditPage + Products/Edit suites green, prettier/lint clean, typecheck clean.
- [ ] Shipped — draft; awaiting CI + premerge review.
- [x] Market — n/a, editor save correctness
- [x] Sell — n/a

## Test Results

```text
npx vitest run app/javascript/data/product_edit.test.ts
# at 2fbbc719b
Test Files  1 passed (1)
Tests  25 passed (25)   # 23 original + 2 new PWYW cases

npx vitest run app/javascript/components/server-components/ProductEditPage.test.tsx app/javascript/pages/Products/Edit.test.tsx
# at 2fbbc719b
Test Files  2 passed (2)
Tests  17 passed (17)

Mutation proof (revert fix -> test reddens):
  scalarSettingsForSave changed to always send customizable_price
  -> "omits an unchanged customizable_price so a stale tab cannot turn PWYW off" FAILS (proves the new test pins the behavior)

npx tsc --noEmit -p tsconfig.json  # at 2fbbc719b: 0 errors
npx eslint <edited files> --max-warnings 0  # only pre-existing environmental Routes.* errors (also on untouched Boundary.tsx)
```

## QA steps

1. Open a product editor, turn on pay-what-you-want, save.
2. Edit the description/content tab and save again.
3. Reload: PWYW is still on.
4. From the same session, deliberately toggle PWYW off and save: it stays off.

No rendered surface — the change is the save payload's scalar omission. Specs are the reviewable artifact.

---

## AI disclosure

Generated with the default model from `~/.hermes/config.yaml`, running as Gumclaw. Prompts/instructions: GitHub issue dispatch; autonomous product-dev pipeline. This is the #2348 PWYW remainder split out of the already-merged #7450.