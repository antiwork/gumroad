# JP Stripe account disabled on a kanji or kana address field

A Japanese Stripe account can stay disabled on an address field our compliance record already holds correctly.
The usual case is a town that Stripe did not accept earlier.
The account shows `individual.address_kanji.town` and `individual.address_kana.town` under `requirements.past_due` or `currently_due`, `charges_enabled` is false, and payouts fail at the account level.
For a business, the fields start with `company.` instead.

## What the app does

Every compliance-info change syncs through `StripeMerchantAccountManager.update_account`; a save that changes nothing never reaches Stripe.
For a JP account it re-sends each `address_kanji` or `address_kana` field that Stripe lists as due and the record holds, even when the save did not change it.
It never sends a blank, and it skips fields the record does not have.
While a postal-code payout note is outstanding it re-sends nothing; the weekly retry's `force_address_resync` handles that case.
If Stripe rejects a re-sent field as an invalid Japanese address, the save retries once without the re-sent fields, so the rest of that save still lands while the account stays disabled on the address.
It records Stripe's rejection as a payout note (`Stripe rejected payout setup`), and the seller sees a note asking them to correct the address.

An account fixes itself only on the seller's next compliance-info change.
An account with no change since the rejection needs the manual resync below.

## Diagnose

1. Read the live requirements:

   ```ruby
   user = User.find(user_id)
   Stripe::Account.retrieve(user.stripe_account.charge_processor_merchant_id).requirements
   ```

2. Compare each due address field with `user.alive_user_compliance_info`.
   The town is `street_address_kanji` / `street_address_kana`, the city is `city` / `city_kana`, and the postal code is `zip_code`.
3. If the record holds the values and they match the postal code, the seller does not need to re-enter the address.

## Resync

Run this through the approved production write workflow:

```ruby
StripeMerchantAccountManager.update_account(
  user,
  passphrase: GlobalConfig.get("STRONGBOX_GENERAL_PASSWORD"),
  force_address_resync: true
)
```

Then read the requirements again.
If the address fields are gone, the resync worked.
Stripe may then ask for `individual.verification.document`, which the seller uploads themselves.

If Stripe rejects the call with `Invalid address for Japan ... town of X for postal_code Y`, the record itself does not match the postal code.
Ask the seller to correct the address in their payout settings.

Keep an internal payout pause until the live account shows `payouts_enabled`.
Unpausing while Stripe still disables payouts only produces another failed payout.
