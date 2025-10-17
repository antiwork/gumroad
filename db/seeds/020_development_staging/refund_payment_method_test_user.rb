# frozen_string_literal: true

# Test user specifically for testing refund payment method feature
test_user = User.find_by(email: "refund-test@gumroad.com")
if test_user.blank?
  test_user = User.new
  test_user.email = "refund-test@gumroad.com"
  test_user.name = "Refund Test User"
  test_user.username = "refundtest"
  test_user.confirmed_at = Time.current
  test_user.user_risk_state = "compliant"
  test_user.password = SecureRandom.hex(24)

  # Make user eligible for service products
  test_user.created_at = 2.months.ago

  # Add some earnings that have already been paid out (creates $0 balance)
  test_user.payments.build(
    state: "completed",
    amount_cents: 3000,
    processor: "paypal",
    processor_fee_cents: 150,
    payout_period_end_date: 1.week.ago
  )

  test_user.save!

  test_user.password = "password"
  test_user.save!(validate: false)

  puts "Created test user: refund-test@gumroad.com / password"
  puts "This user has $0.00 balance (all earnings paid out)"
else
  puts "Test user already exists: refund-test@gumroad.com / password"
end
