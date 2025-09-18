# Gumroad Admin Operations

This document contains various administrative operations for Gumroad.
To use, run these commands in the production console.

## Payout operations

### Process a PayPal payout for a specific user

```ruby
PayoutUsersService.new(
  date_string: "2025-4-18",
  processor_type: "PAYPAL",
  user_ids: User.find_by(email: "my@email.com").id
).process
```

### Process a Stripe/Bank payout for a specific user

```ruby
PayoutUsersService.new(
  date_string: "2025-4-18",
  processor_type: "STRIPE",
  user_ids: User.find_by(email: "my@email.com").id
).process
```

### Unpause payouts for a specific user

```ruby
User.find_by(email: 'my@email.com').update!(payouts_paused_internally: false)
```

### Update payment address for a specific user

```ruby
User.find_by(email: 'my@email.com').update!(payment_address: "my@email.com")
```

### Enable Stripe Connect for a specific user

```ruby
User.find_by(email: 'my@email.com').update!(can_connect_stripe: true)
```

### Issue smaller amounts

Check unpaid balance up to specific dates to find the closest amount to what you want to pay out:

```ruby
User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-23")
User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-22")
User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-21")
User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-20")
```

Once you've identified the appropriate date, issue a payout up to that date:

```ruby
PayoutUsersService.new(
  date_string: "2025-4-20", # Use the date that gives the closest amount to what you want to pay out
  processor_type: "STRIPE",
  user_ids: User.find_by(email: "creator@example.com").id
).process
```

### Get details of last 5 payouts for a user

```ruby
User.find_by(email: 'creator@example.com').payments.select(:id, :created_at, :processor, :amount_cents, :currency, :state).last(5)
```

### Check last 2 failed payouts for a user

```ruby
User.find_by(email: 'creator@example.com').payments.failed.last(2)
```

### Cancel a payout

If it has not been triggered on Stripe/PayPal, can just mark it as failed:

```ruby
Payment.find(PAYMENT_ID).mark_failed!
```

### Mark unclaimed/canceled payout as returned

```ruby
Payment.find(PAYMENT_ID).mark_returned!
```

### Find PayPal Connect email for a user

```ruby
User.find_by(email: "creator@example.com").paypal_connect_account.paypal_account_details["primary_email"]
```

### Look up PayPal merchant account by ID

```ruby
PaypalIntegrationRestApi.new(nil, authorization_header: PaypalPartnerRestCredentials.new.auth_token).get_merchant_account_by_merchant_id("MERCHANT_ID")["primary_email"]
```

## Payment operations

### Find purchase ID by creator and customer email

```ruby
User.find_by(email: 'creator@example.com').sales.successful.where(email: 'customer@example.com').pluck(:id, :created_at, :stripe_transaction_id, :total_transaction_cents)
```

### Find purchase ID by customer email only (shows last 25)

```ruby
Purchase.successful.where(email: 'customer@example.com').select(:id, :created_at, :stripe_transaction_id, :total_transaction_cents).last(25)
```

### Process refund by purchase ID

```ruby
Purchase.find(purchase_id).refund!(refunding_user_id: GUMROAD_ADMIN_ID)
```

### Process refund by external ID

```ruby
Purchase.find_by_external_id(purchase_external_id).refund!(refunding_user_id: GUMROAD_ADMIN_ID)
```

### Find PayPal purchases from a charge ID

```ruby
Charge.find_by_external_id("abcdefghijklmno==").purchases
```

## Product management

### Undelete a product

```ruby
User.find_by_username("<username>").links.f("<permalink>").mark_undeleted!
```

### Remove custom receipt text (using product URL)

```ruby
product = Link.find_by_unique_permalink("<username>.gumroad.com/l/abcde")
product.update!(custom_receipt: nil)
```

### Remove custom receipt text (using custom permalink)

```ruby
product = Link.find_by(email: 'creator@example.com', custom_permalink: 'customname')
product.update!(custom_receipt: nil)
```

Alternative method:

```ruby
user = User.find_by(email: 'creator@example.com')
product = user.links.find_by(unique_permalink: 'PERMALINK')
product.update!(custom_receipt: nil)
```

### Remove rental option

```ruby
user = User.find_by(email: 'creator@example.com')
product = user.links.find_by(unique_permalink: 'PERMALINK')
product.update(purchase_type: :buy_only)
```

## User management

### Restore refunding capability

```ruby
u = User.find_by(email: 'creator@example.com')
u.update!(refunds_disabled: false)
```

### Remove old email from checkout

Get the current email:

```ruby
User.find_by(email: "customer@example.com").alive_cart.email
```

Remove the email:

```ruby
User.find_by(email: "customer@example.com").alive_cart.update!(email: nil)
```

### Get user's annual sales report URL

```ruby
User.find_by(email: "creator@example.com").financial_annual_report_url_for(year: 2024)
```

### Find user ID

```ruby
User.find_by(email: 'creator@example.com').id
```

### Confirm user email

```ruby
user = User.find_by(email: 'creator@example.com')
# or
user = User.find_by(id: USER_ID)
user.confirm
```

### Refresh purchases in user's library

```ruby

user = User.find_by(email: "customer@example.com")
if user.present?
  Purchase.where(email: user.email, purchaser_id: nil).update_all(purchaser_id: user.id)
else
  # Handle case when user doesn't exist
  puts "No user found with email: customer@example.com"
end
```

### Resend all receipts

```ruby
email = "customer@example.com"

purchases = Purchase.successful
                .where(email: email)
                .not_is_gift_sender_purchase
                .not_is_bundle_product_purchase

purchases.find_each do |purchase|
  purchase.resend_receipt
end
```

## Subscription management

### Check subscription cancellation date

```ruby
Subscription.find(SUBSCRIPTION_ID).user_requested_cancellation_at
```

### CAUTION: Cancel all active subscriptions for a creator

```ruby
User.find_by_email("creator@example.com").links.each do |product|
    product.subscriptions.active.each do |subscription|
        subscription.cancel!(by_admin: true)
    end
end
```
