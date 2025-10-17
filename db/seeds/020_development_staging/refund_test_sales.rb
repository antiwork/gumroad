# frozen_string_literal: true

# Add test sales to the refund test user for testing refund functionality
# Load the test merchant account first
load 'db/seeds/020_development_staging/test_merchant_account.rb'

refund_test_user = User.find_by(email: "refund-test@gumroad.com")

if refund_test_user.present?
  # Create a test product (Link) if it doesn't exist
  product = Link.where(user: refund_test_user, name: "Refund Test Product").first
  if product.blank?
    product = Link.new(
      user: refund_test_user,
      name: "Refund Test Product",
      price_cents: 1000, # $10.00
      price_currency_type: "usd",
      draft: false, # published = true
      native_type: "digital",
      unique_permalink: "refund-test-product-#{SecureRandom.hex(4)}"
    )
    product.save!(validate: false) # Skip validations for quick seeding
  end

  # Create a test customer
  customer = User.find_by(email: "test-customer@gumroad.com")
  if customer.blank?
    customer = User.new(
      email: "test-customer@gumroad.com",
      name: "Test Customer",
      username: "testcustomer",
      confirmed_at: Time.current,
      is_team_member: false,
      user_risk_state: "compliant",
      password: "password"
    )
    customer.save!(validate: false)
  end

  # Create test purchases using the working pattern from existing seeds
  purchase_count = Purchase.where(seller: refund_test_user).count
  if purchase_count < 3
    # Create 3 test purchases following the exact pattern from working seeds
    3.times do |i|
          purchase = Purchase.new(
            link_id: product.id,
            seller_id: refund_test_user.id,
            purchaser_id: customer.id,
            price_cents: 1000,
            displayed_price_cents: 1000,
            tax_cents: 0,
            gumroad_tax_cents: 0,
            total_transaction_cents: 1000,
            email: customer.email,
            card_country: "US",
            ip_address: "127.0.0.1",
            charge_processor_id: "stripe",
            stripe_status: "succeeded",
            stripe_transaction_id: "ch_test_#{SecureRandom.hex(8)}",
            created_at: (i + 1).days.ago
          )

      # Calculate fees and save (following working seed pattern)
      purchase.send(:calculate_fees)
      purchase.save!

      # Set the test merchant account ID
      purchase.update_columns(
        purchase_state: "successful",
        succeeded_at: (i + 1).days.ago,
        merchant_account_id: TEST_MERCHANT_ACCOUNT_ID
      )

      puts "✅ Created purchase #{i + 1}"
    end

    puts "✅ Created 3 test sales for refund-test@gumroad.com"
    puts "   - Total sales: $30.00"
    puts "   - Ready to test refund functionality!"
  else
    puts "✅ Test sales already exist for refund-test@gumroad.com"
  end

  puts "✅ Set up test user for refund payment method testing"
  puts "   - User: refund-test@gumroad.com"
  puts "   - Product: Refund Test Product ($10.00)"
  puts "   - Current balance: $#{refund_test_user.unpaid_balance_cents / 100.0}"
  puts "   - Ready to test refund payment method feature!"
else
  puts "❌ Refund test user not found. Please run the refund test user seed first."
end
