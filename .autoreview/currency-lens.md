# Currency / minor-unit review lenses (from gumroad#6936, sales-API `currency` field)

Apply these whenever a diff touches currency codes, `amount_cents` params, refund scaling,
or API docs that explain money units.

## 1. Docs describing a unit rule ≠ the rule the server implements
Gumroad's scaling authority is `unit_scaling_factor` (app/helpers/currency_helper.rb),
driven by the `single_unit` flag in `config/currencies.json` — set **only for `jpy`**.
KRW and TWD are ISO-4217/Stripe zero-decimal but Gumroad scales them by **100**.
Any doc/comment that says "zero-decimal currencies have no minor units" teaches callers
the ISO rule and reintroduces the 100x refund mis-scale for KRW/TWD. Correct phrasing:
"every currency has 100 minor units except `jpy`". Lens: for every documented money rule,
grep for the function that actually implements it and diff the two rules — a docs-only
divergence is a P2 money-safety finding, not a nit.

## 2. Two-candidate source fields: does the spec kill the wrong-source mutant?
Purchases have both `link.price_currency_type` (live product setting) and
`purchase.displayed_price_currency_type` (charge-time snapshot via `set_price_and_rate`,
which refunds actually use). A fixture that sets BOTH to the same value cannot
distinguish them — a mutant reading the wrong one stays green. Fix pattern: create the
purchase, then mutate the product-side field (`product.update!(price_currency_type: "usd")`)
and re-assert the snapshot value. Generalize: whenever a serializer/endpoint could read
either of two columns that agree in every fixture, demand a spec where they DIVERGE.

## 3. Factory snapshots are load-bearing, not redundant
`create(:purchase, ...)` never runs `set_price_and_rate`; `displayed_price_currency_type`
falls back to the column default `"usd"`. An explicit `displayed_price_currency_type:`
in a fixture may look redundant next to a same-currency product but is required for the
spec to pass at all. Don't flag it for removal — flag that it masks lens #2 instead.

## 4. Version-gated serializer keys: check the nil-strip and ALL consumers
`(value if version == 2)` + trailing `.delete_if { |_, v| v.nil? }` keeps v1 payloads
byte-identical — verify the delete_if actually survives the merge. Then grep every
`version: 2` call site: in gumroad, `purchases_controller#search` (internal
customers/mobile payload) shares the v2 serializer with the public Sales API, so any new
key ships to both. No in-repo exact-shape validators (typia assertEquals / snapshots) on
this payload as of 2026-08, but re-check before calling additive changes safe.

## 5. Adjacent-currency ambiguity
When a sale object carries more than one currency (`currency` vs
`buyer_presentment.currency`), check the amount-param docs say explicitly which one the
server reads, and check the server comment for the invariant making the other reading
harmless today (here: both can't be non-USD and differ — see sales_controller#refund
comment; breaks if gumroad-private#1321 lands).
