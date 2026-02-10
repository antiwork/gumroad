#!/usr/bin/env ruby
# Quick script to create a test purchase and show receipt URL

# Run this in Rails console: bin/rails console
# Or save as script and run: bin/rails runner scripts/create_test_purchase.rb

puts "Creating test purchase..."

# Create a buyer (or use existing)
buyer = User.find_or_create_by!(email: "testbuyer@example.com") do |u|
  u.name = "Test Buyer"
  u.username = "testbuyer#{rand(1000..9999)}"
  u.password = "password123"
  u.user_risk_state = "compliant"
  u.confirmed_at = Time.current
end

# Find any product (or create one)
product = Link.alive.first
if product.nil?
  puts "❌ No products found! Please create a product first."
  exit 1
end

# Create purchase
purchase = Purchase.new(
  link_id: product.id,
  seller_id: product.user_id,
  price_cents: product.price_cents || 1000,
  displayed_price_cents: product.price_cents || 1000,
  tax_cents: 0,
  gumroad_tax_cents: 0,
  total_transaction_cents: product.price_cents || 1000,
  purchaser_id: buyer.id,
  email: buyer.email,
  card_country: "US",
  ip_address: "127.0.0.1",
  purchase_state: "successful",
  succeeded_at: Time.current
)

purchase.send(:calculate_fees)
purchase.save!

puts "\n✅ Test purchase created!"
puts "\n📋 Receipt URL:"
puts "#{PROTOCOL}://#{DOMAIN}/purchases/#{CGI.escape(purchase.external_id)}/receipt?email=#{CGI.escape(purchase.email)}"
puts "\nℹ️  Access this URL in your browser (logged in as buyer or seller, or use the email param)"
