## Status

**Only human merge remains: Gianfranco to review and merge antiwork/gumroad#7686.** No further product decision or second PR is needed; do not merge automatically.

- [x] AE invalid-structure leak: antiwork/gumroad#7648 merged (`37fada48fcfaa329fb5c5d12dcd0a1311f1870a8`), included in live release `v2026.09.15.1` (compare: ahead 4, behind 0).
- [x] Items 1 and 3 built in antiwork/gumroad#7686 at `37dfec6b0998c5c87ad0c77b63bdf75cfbd3af8a`: US member-count choices and structure mapping; create/update use the legal-entity country. Correction to the original diagnosis: `_update_account` already assigned its local `country_code` from `legal_entity_country_code`; the create condition needed changing.
- [x] Greptile P1 fixed: a stored type outside the active list renders `Type` and fails existing save validation until reselected; no LLC member count is guessed. P2 comments trimmed and real before/after desktop/mobile, light/dark evidence attached. Vitest 22/22; focused Stripe RSpec 19/19 and browser RSpec 2/2; revert proofs fail; current-head panel clean; CI 81 successful checks, 17 skipped, none pending/failed.
- [x] Item 2 decided: **no change** to AE reach and no business-country restriction. Stripe says [company structure is optional](https://docs.stripe.com/connect/identity-verification?country=AE#business-structure); its [AE company requirements](https://docs.stripe.com/connect/required-verification-information?country=AE&business-type=company) require company registration `tax_id`, not `vat_id`, and do not mandate `structure`. No residence-based extra requirement for those fields is documented, so expanding their submission or blocking valid cross-border businesses is unwarranted.
- [ ] Gianfranco: review and merge antiwork/gumroad#7686 (ready, `awaiting-human`).

AE evidence: audited read-only console query at 2026-09-16 03:01 UTC found **22** current non-deleted accounts whose latest live compliance record has `is_business=true`, UAE business country, and non-UAE residence; **18** have a live Stripe merchant record. Replica lag was 1 second. Query used a 30-second cap after EXPLAIN; audit `20260916T030137Z-dfb1990e` (request/result verified). These are not zero, but Stripe's optional-field rule makes a second PR unnecessary.

Affected seller: audited read at 2026-09-16 03:05 UTC shows AE residence, US business, legacy `llc`, no live Stripe record, and publishing blocked. Once #7686 ships and they choose their actual LLC member count, the reported `company[structure]` save blocker is removed. Other Stripe/KYC checks may still apply; they are not unblocked by this unmerged PR today. PayPal remains the interim path. No seller email or production mutation performed.

Main-sync conflict in `Show.test.tsx` resolved with both the Egyptian bank-code and US business-type suites preserved. Auto-merge was found armed and disabled; verified off. The PR links this tracker for automatic closure on merge.

Session astra/2609-20260915 released; `working` removed. The original incident/diagnosis below is historical.

## Summary

A UAE-based account that declares a US-registered business can never save its payout settings. Every save is rejected by Stripe on `company[structure]`, the merchant account is never created, so the seller has no payout method and cannot publish products.

Affected: `pemberleymedia@gmail.com` (user id `28984224`, username `pemberley4`, created 2026-09-14, account country United Arab Emirates, 0 sales, $0.00 balance).
Ticket: Help Center contact form, Gmail thread `1a09ffd21cef7dce` ("I cant connect my stripe account?").

## What the live state shows

Compliance record: `is_business=true`, `country="United Arab Emirates"`, `business_country="United States"`, `business_name="Pemberley Media LLC"`, `business_type="llc"`, US Ach account entered.

Repeated admin `payout_note` comments, every save attempt between 12:19 and 12:33 UTC on 2026-09-14:

```
Stripe rejected payout setup: code=unknown param=company[structure] — 'llc' is not a valid structure in the country US and under the business type 'company'.
Our payment partner couldn't accept the details you entered. Please correct it here and save again — until it goes through you have no payout method, which also stops you publishing new products.
```

Console: 13 `MerchantAccount` rows, all soft-deleted, **every one with `charge_processor_merchant_id` NULL** (Stripe account creation never succeeded) and `country="US"`. 9 bank rows (8 soft-deleted, 1 alive US `AchAccount`). `payouts_paused_internally=false`, `payouts_paused_by_user=false`, no live Stripe account, `can_publish_products? == false`.

## Cause

`StripeMerchantAccountManager.company_hash` (`app/business/payments/merchant_registration/implementations/stripe/stripe_merchant_account_manager.rb:2154`, merged into the create payload at line 1945) branches on **`user_compliance_info.country_code == ARE`** — the UCI's account/residence country — and sends `company.structure = user_compliance_info.business_type` (`"llc"`).

But the Stripe account is created for the legal entity country: `business_type: "company"`, `company[address][country]` / `legal_entity_country_code` = `"United States"` (the merchant account row is `country="US"`). Stripe validates `company[structure]` against the account country, and `"llc"` is not a US company structure, so creation fails on every attempt.

The Canada branch immediately below (line 2162) correctly tests `legal_entity_country_code`; the AE branch is the outlier.

Compounding factor on the UI side: the business-type list is chosen from `business_country` (`app/javascript/components/Settings/PaymentsPage/AccountDetailsSection.tsx:104-109`; only AE / IN / CA have lists), so `business_country="US"` falls back to the generic list (`llc`, `partnership`, `profit`, `sole_proprietorship`, `corporation`). None of those except `sole_proprietorship` is a valid US Stripe structure — consistent with `_update_account` (line ~455) only sending structure for US accounts when `business_type == sole_proprietorship`.

## Suggested fix (product call)

1. Minimal: test `legal_entity_country_code` in the AE branch instead of `country_code` (match the CA branch), so a US legal entity never gets a UAE business type sent as its Stripe structure.
2. Needed to fully unblock: Stripe will then surface `company.structure` as a requirement, and the generic US list still offers no valid value — so either map the generic business types to real Stripe US structures (`single_member_llc`, `multi_member_llc`, `private_corporation`, `private_partnership`) or restrict/validate the business country selection for AE accounts.

## Repro

Any account with `country_code == "AE"` and `is_business && business_country` != AE (e.g. US) + a generic business type, saving Settings → Payments. Stripe rejects account creation with `company[structure]`.

Discovered while working the ticket above; the seller is being given the interim PayPal path in the reply.

