# Money-path QA lens for gp#2275

Review only the child diff against the parent branch `gumclaw/fix-nil-flow-of-funds`, not all of #7340.

The intended design:

1. #7340 keeps seller-held Stripe nil `flow_of_funds` nil instead of synthesizing USD.
2. This child PR should defer those seller-held missing-settlement purchases, preserving charge data and leaving them `in_progress` until Stripe exposes real settlement data.
3. It must not widen deferral to Gumroad-held non-presentment nil flows, because #7340 intentionally synthesizes USD there.
4. It must not grant content or receipt affordances before the retry path books balances.
5. Specs must fail if any of the seller-held gates are removed: checkout charge gate, purchase sync gate, and finalize job gate.

Look especially for: mixed carts where one charge owns multiple purchases, SCA/client-confirm paths, finalizer jobs exiting too early, and any path that can call `MarkSuccessfulService` with nil seller-held flow of funds.