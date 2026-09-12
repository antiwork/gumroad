Fixes the documentation half of antiwork/gumroad-private#2573. The product decision on that issue (whether PWYW can coexist with a paid version on a $0-base product) stays open with @gianfrancopiana.

## What

Help article 133 (`_133-pay-what-you-want-pricing`) told sellers that when a product has versions that add to the price they should "turn on *Allow customers to pay what they want* yourself after setting the Amount to $0." The product refuses that:

- `app/modules/product/prices.rb` `set_customizable_price` writes `customizable_price = false` whenever the base is $0 and the alive variants sum `price_difference_cents > 0` (gumroad#6906, merged `6d1372d`).
- `app/javascript/components/ProductEdit/ProductTab/PriceEditor.tsx:64` — `cannotBePWYW` disables the switch and renders "Pay what you want isn't available on products with paid pricing options."

The sentence sent sellers into the exact loop the article exists to resolve. It now states the real behavior plus the setup that does work (Amount $0, free version at Additional amount $0, paid versions at their price), which matches what `_126-setting-up-versions-on-a-digital-product` already says.

Body-only edit: no `articles.yml`, code, or ERB-logic change; a pure copy edit, so no adversarial review gate applies.

## Why

A seller was following this article and could not reproduce the layout it describes (rows and thread in antiwork/gumroad-private#2573). The guard shipped 2026-08-03 and the article was never updated with it.

## QA steps

Docs-only change; no preview deploy is needed to verify the file, but the branch preview serves it.

1. Before: https://help.gumroad.com/help/article/133-pay-what-you-want-pricing — "Create a free product" lists "turn on *Allow customers to pay what they want* yourself after setting the Amount to $0."
2. After: <branch preview>/help/article/133-pay-what-you-want-pricing — the same list item now names the disabled toggle and the free-version-plus-paid-version setup.
3. Post-merge spot-check: https://help.gumroad.com/help/article/133-pay-what-you-want-pricing
4. Wording cross-check against `Product::Prices#set_customizable_price` and `PriceEditor.tsx` above.

## Related

- antiwork/gumroad#6906 (the guard), gumroad-private#1660 (its rationale), gumroad-private#2342 (the editor half).

## Checklist

- [x] Scope
- [x] Design
- [x] Build
- [x] QA
- [ ] Shipped
- [ ] Market
- [ ] Sell

AI disclosure: deepseek/deepseek-v4.1-flash (OpenRouter). Prompt: fix the help-center doc defect filed in gumroad-private#2573.
