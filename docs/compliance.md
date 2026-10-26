# Compliance & Risk

This document contains instructions for running various compliance scripts for Gumroad.

To use, run these commands in the production console.

## User compliance

### Suspend users for ToS violation

```rb
user_ids = []

users = User.find(user_ids)
users.each do |user|
  begin
    user.flag_for_tos_violation!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for TOS violation on #{Time.current.to_fs(:formatted_date_full_month)}",
      bulk: true
    )
    user.suspend_for_tos_violation!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for TOS violation on #{Time.current.to_fs(:formatted_date_full_month)}",
      bulk: true
    )
  rescue => e
    puts "Error processing user #{user.id}: #{e.message}"
  end
end
```

### Suspend users for fraud

```rb
user_ids = []

users = User.find(user_ids)
users.each do |user|
  begin
    user.flag_for_fraud!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for fraud on #{Time.current.to_fs(:formatted_date_full_month)}"
    )
    user.suspend_for_fraud!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for fraud on #{Time.current.to_fs(:formatted_date_full_month)}"
    )
  rescue => e
    puts "Error processing user #{user.id}: #{e.message}"
  end
end
```

### Suspend for fraud and refund user purchases

```rb
user_ids = []

users = User.find(user_ids)
users.each do |user|
  begin
    user.flag_for_fraud!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for fraud on #{Time.current.to_fs(:formatted_date_full_month)}"
    )
    user.suspend_for_fraud!(
      author_id: GUMROAD_ADMIN_ID,
      content: "Suspended for fraud on #{Time.current.to_fs(:formatted_date_full_month)}"
    )
    user.sales.where(purchase_success_balance_id: user.unpaid_balances.pluck(:id)).not_fully_refunded.not_chargedback_or_chargedback_reversed.each do |purchase|
      begin
        next if user.unpaid_balance_cents <= 0
        purchase.refund!(refunding_user_id: GUMROAD_ADMIN_ID)
      rescue => e
        puts "Error refunding purchase #{purchase.id} for user #{user.id}: #{e.message}"
      end
    end
  rescue => e
    puts "Error processing user #{user.id}: #{e.message}"
  end
end
```

### Mark users compliant (unsuspend users)

```rb
user_ids = []

users = User.find(user_ids)
users.each do |user|
  begin
    user.mark_compliant!(author_name: "Iffy")
  rescue => e
    puts "Error processing user #{user.id}: #{e.message}"
  end
end
```

## Listings

### Hold sales of one listing

This goes through the internal admin API, not the console, and needs a per-actor admin token. Both calls are audited against the product, and both answer 409 without writing if the seller or the product's owner changed after the lookup.

```sh
# Hold. The response's sales_hold.id is what a release needs.
curl -X POST "$API/internal/admin/products/$PRODUCT_ID/hold_sales" \
  -H "Authorization: Bearer $TOKEN" -d user_id=$SELLER_ID

# Release that hold. A release of an older hold leaves a newer one in place.
curl -X POST "$API/internal/admin/products/$PRODUCT_ID/release_sales_hold" \
  -H "Authorization: Bearer $TOKEN" -d user_id=$SELLER_ID -d hold_id=$HOLD_ID
```

A hold unpublishes the listing if it is live and stops every seller publish path (web, API, Muse, bundles) from relisting it. It leaves the account, its other listings, files, content, custom domain and profile sections alone, and sends no email.

It stops new checkouts only, including checkouts of any bundle that contains the listing. Recurring charges, preorder charges, upgrades of existing memberships, commission completions and the seller's own test purchases skip the sale check. A checkout that got past the check before the hold, bundle or not, still completes and is not cancelled. Existing buyers of a bundle that the seller later adds the listing to can still be given it by the bundle's content update.

The hold follows one product ID. A duplicate of the listing, or a new listing with the same content, is not held.

A release only lifts the hold. If the hold unpublished the listing (`unpublished_listing: true`), it stays unpublished until the seller publishes it again.

## Purchases

### Refund purchases

```rb
purchase_ids = []

purchase_ids.each do |purchase_id|
  begin
    purchase = Purchase.not_fully_refunded.not_chargedback_or_chargedback_reversed.find_by(id: purchase_id)
    if purchase
      purchase.refund!(refunding_user_id: GUMROAD_ADMIN_ID)
    end
  rescue => e
    puts "Error processing purchase #{purchase_id}: #{e.message}"
  end
end
```

## Payouts

### Issue payouts

```rb
user_ids = []

payout_date = User::PayoutSchedule.manual_payout_end_date

user_ids.each do |user_id|
  begin
    user = User.find_by(id: user_id)
    if user
      payout_processor_type = if user.active_bank_account.present?
        PayoutProcessorType::STRIPE
      elsif user.paypal_payout_email.present?
        PayoutProcessorType::PAYPAL
      else
        nil
      end

      if payout_processor_type.blank?
        next
      end

      if Payouts.is_user_payable(user, payout_date, processor_type: payout_processor_type, add_comment: true, from_admin: true)
        payments = PayoutUsersService.new(date_string: payout_date,
                                        processor_type: payout_processor_type,
                                        user_ids: [user.id]).process
        payment = payments.first

        if payment&.persisted? && (payment.processing? || payment.completed?)
        else
          error_message = payment&.errors&.full_messages&.to_sentence || "Unable to create payout"
          puts "Error creating payout for user #{user.id}: #{error_message}"
        end
      else
        payout_note = user.reload.comments.with_type_payout_note.where(author_id: GUMROAD_ADMIN_ID).last&.content
        payout_note&.gsub!("via #{payout_processor_type.capitalize} on #{payout_date.to_fs(:formatted_date_full_month)} ", "")
        message = "User is not eligible for payout."
        message += " #{payout_note}" if payout_note.present?
        puts "User #{user.id} not eligible: #{message}"
      end
    end
  rescue => e
    puts "Error processing user #{user_id}: #{e.message}"
  end
end
```
