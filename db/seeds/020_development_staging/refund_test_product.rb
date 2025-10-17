# frozen_string_literal: true

# Test product for refund payment method testing
test_user = User.find_by(email: "refund-test@gumroad.com")
return unless test_user

test_product = Link.where(user: test_user, name: "Refund Test Product").first
if test_product.blank?
  test_product = Link.create!(
    user: test_user,
    name: "Refund Test Product",
    price_cents: 1000,
    default_price_cents: 1000,
    price_currency_type: "usd",
    draft: false,
    native_type: "digital",
    unique_permalink: "refund-test-product-#{SecureRandom.hex(4)}",
    created_at: 1.month.ago
  )

  puts "Created test product: '#{test_product.name}' for $#{test_product.price_cents / 100.0}"
else
  puts "Test product already exists: '#{test_product.name}'"
end
