#!/usr/bin/env ruby

# Gumroad Admin Operations
#
# This script contains various administrative operations for Gumroad.
# To use, run these in production console
#


# =============================================================================
# PAYOUT OPERATIONS
# =============================================================================

# Process a PayPal payout for a specific user
 PayoutUsersService.new(
   date_string: "2025-4-18",
   processor_type: "PAYPAL",
   user_ids: User.find_by(email: "my@email.com").id
 ).process

# Process a Stripe/Bank payout for a specific user
 PayoutUsersService.new(
   date_string: "2025-4-18",
   processor_type: "STRIPE",
   user_ids: User.find_by(email: "my@email.com").id
 ).process

# Unpause payouts for a specific user
 User.find_by(email: 'my@email.com').update!(payouts_paused_internally: false)

# Update payment address for a specific user
 User.find_by(email: 'my@email.com').update!(payment_address: "my@email.com")

# Enable Stripe Connect for a specific user
 User.find_by(email: 'my@email.com').update!(can_connect_stripe: true)


# Issue smaller amounts
# Check unpaid balance up to specific dates to find the closest amount to what you want to pay out
 User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-23")
 User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-22")
 User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-21")
 User.find_by(email: 'creator@example.com').unpaid_balance_cents_up_to_date("2025-4-20")

# Once you've identified the appropriate date, issue a payout up to that date
 PayoutUsersService.new(
   date_string: "2025-4-20", # Use the date that gives the closest amount to what you want to pay out
   processor_type: "STRIPE",
   user_ids: User.find_by(email: "creator@example.com").id
 ).process

# Get details of last 5 payouts for a user
 User.find_by(email: 'creator@example.com').payments.select(:id, :created_at, :processor, :amount_cents, :currency, :state).last(5)

# Check last 2 failed payouts for a user
 User.find_by(email: 'creator@example.com').payments.failed.last(2)

# =============================================================================
# PAYMENT OPERATIONS
# =============================================================================

# Find purchase ID by creator and customer email
 User.find_by(email: 'creator@example.com').sales.successful.where(email: 'customer@example.com').pluck(:id, :created_at, :stripe_transaction_id, :total_transaction_cents)

# Find purchase ID by customer email only (shows last 25)
 Purchase.successful.where(email: 'customer@example.com').select(:id, :created_at, :stripe_transaction_id, :total_transaction_cents).last(25)

 Update payment address for a specific user
 User.find_by(email: 'my@email.com').update!(payment_address: "my@email.com")

 # Process refund by purchase ID
 Purchase.find(purchase_id).refund!(refunding_user_id: GUMROAD_ADMIN_ID)

 Enable Stripe Connect for a specific user
 User.find_by(email: 'my@email.com').update!(can_connect_stripe: true)

 # Process refund by external ID
 Purchase.find_by_external_id(purchase_external_id).refund!(refunding_user_id: GUMROAD_ADMIN_ID)

# Find PayPal purchases from a charge ID
 Charge.find_by_external_id("abcdefghijklmno==").purchases

# =============================================================================
# PRODUCT MANAGEMENT
# =============================================================================

# Undelete a product
 User.find_by_username("<username>").links.f("<permalink>").mark_undeleted!

# Remove custom receipt text (using product URL)
 product = Link.find_by_unique_permalink("<username>.gumroad.com/l/abcde")
 product.update!(custom_receipt: nil)

# Remove custom receipt text (using custom permalink)
 product = Link.find_by(email: 'creator@example.com', custom_permalink: 'customname')
 product.update!(custom_receipt: nil)

# =============================================================================
# USER MANAGEMENT
# =============================================================================

# Restore refunding capability
 u = User.find_by(email: 'creator@example.com')
 u.update!(refunds_disabled: false)

# Remove old email from checkout
 User.find_by(email: "customer@example.com").alive_cart.email
 User.find_by(email: "customer@example.com").alive_cart.update!(email: nil)

 # Get user's annual sales report URL
User.find_by(email: "creator@example.com").financial_annual_report_url_for(year: 2024)


# =============================================================================
# SUBSCRIPTION MANAGEMENT
# =============================================================================

# Check subscription cancellation date
 Subscription.find(123456).user_requested_cancellation_at

# Cancel all active subscriptions for a user
 User.find_by_email("creator@example.com").links.each do |product|
     product.subscriptions.active.each do |subscription|
         subscription.cancel!(by_admin: true)
     end
 end
