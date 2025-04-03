# frozen_string_literal: true

# Create the shared Stripe merchant account
if MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).nil?
  merchant_account_stripe = MerchantAccount.new
  merchant_account_stripe.charge_processor_id = StripeChargeProcessor.charge_processor_id
  merchant_account_stripe.save!
end
