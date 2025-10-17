# frozen_string_literal: true

# Create a test merchant account for refund testing
# This avoids using Gumroad's real merchant account for test data

test_merchant_account = MerchantAccount.find_by(charge_processor_id: 'stripe', user_id: nil, charge_processor_merchant_id: 'test_merchant_123')
if test_merchant_account.blank?
  test_merchant_account = MerchantAccount.create!(
    charge_processor_id: 'stripe',
    charge_processor_merchant_id: 'test_merchant_123',
    user_id: nil, # This makes it a Gumroad-managed account
    json_data: {
      'meta' => {
        'stripe_connect' => 'false' # This makes it NOT a Stripe Connect account
      }
    }
  )
  puts "✅ Created test merchant account: #{test_merchant_account.id}"
else
  puts "✅ Test merchant account already exists: #{test_merchant_account.id}"
end

# Store the ID for use in other seed files
TEST_MERCHANT_ACCOUNT_ID = test_merchant_account.id
