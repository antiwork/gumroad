# frozen_string_literal: true

require "spec_helper"

describe "1qq factory diagnosis" do
  it "prints the built purchase's transaction fields and errors" do
    seller = create(:user)
    p = build(:purchase, seller: seller)
    p.valid?
    puts "ERRORS=#{p.errors.full_messages.inspect}"
    puts "txn=#{p.stripe_transaction_id.inspect} fp=#{p.stripe_fingerprint.inspect} cp=#{p.charge_processor_id.inspect} ma_id=#{p.merchant_account_id.inspect} price=#{p.price_cents}"
    puts "StripeChargeProcessor platform MA=#{MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id).inspect}"
    puts "Stripe.api_key=#{Stripe.api_key.inspect}"
  end

  it "runs a raw charge through the processor the factory uses" do
    seller = create(:user)
    ma = create(:merchant_account, user: seller)
    charge = StripeChargeProcessor.new.charge!(
      amount_cents: 100,
      currency: "usd",
      metadata: {},
      reference: "1qq-diag",
      customer_id: nil,
      merchant_account: ma,
      token: "tok_visa"
    )
    puts "CHARGE=#{charge.inspect}"
  rescue StandardError => e
    puts "CHARGE_RAISED=#{e.class}: #{e.message}"
  end
end
