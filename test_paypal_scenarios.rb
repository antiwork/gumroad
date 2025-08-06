#!/usr/bin/env ruby
# frozen_string_literal: true

# Test PayPal Connect scenarios
user = User.find_by(email: "seller@gumroad.com")
puts "=== STARTING STATE ==="
puts "Country: #{user.alive_user_compliance_info&.country}"
puts "Earnings: $#{user.sales_cents_total / 100.0}"
puts "Has completed payouts? #{user.has_completed_payouts?}"
puts "Eligible? #{user.eligible_for_paypal_payout?}"

puts "\n=== TEST CASE 1: Adding earnings above $100 ==="
product = user.products.first || user.products.create!(
  name: "Test Product",
  price_cents: 10000,
  summary: "Test",
  content_type: Product::ContentType::DIGITAL
)

_sale = Sale.create!(
  user: user,
  product: product,
  price_cents: 15000,  # $150
  gumroad_fee_cents: 1500,
  seller_earnings_cents: 13500,
  sales_tax_cents: 0,
  currency: "usd"
)

user.reload
puts "Earnings: $#{user.sales_cents_total / 100.0}"
puts "Has completed payouts? #{user.has_completed_payouts?}"
puts "Eligible? #{user.eligible_for_paypal_payout?}"

puts "\n=== TEST CASE 2: Adding completed payout ==="
_payment = Payment.create!(
  user: user,
  amount_cents: 13500,
  state: "completed",
  currency: "usd"
)

user.reload
puts "Earnings: $#{user.sales_cents_total / 100.0}"
puts "Has completed payouts? #{user.has_completed_payouts?}"
puts "Eligible? #{user.eligible_for_paypal_payout?}"

puts "\n=== TEST CASE 3: Change to US with $0 earnings ==="
user_compliance_info = user.fetch_or_build_user_compliance_info
user_compliance_info.dup_and_save! do |new_info|
  new_info.country = "United States"
  new_info.json_data = {}
end

user.sales.destroy_all
user.payments.destroy_all
user.reload

puts "Country: #{user.alive_user_compliance_info.country}"
puts "Earnings: $#{user.sales_cents_total / 100.0}"
puts "Has completed payouts? #{user.has_completed_payouts?}"
puts "Eligible? #{user.eligible_for_paypal_payout?}"

puts "\n=== RESET TO ALGERIA ==="
user_compliance_info = user.fetch_or_build_user_compliance_info
user_compliance_info.dup_and_save! do |new_info|
  new_info.country = "Algeria"
  new_info.json_data = {}
end

user.reload
puts "Country: #{user.alive_user_compliance_info.country}"
puts "Reset complete!"
