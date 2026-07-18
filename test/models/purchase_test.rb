# frozen_string_literal: true

require "test_helper"

# Ported from spec/models/purchase_spec.rb (#3 in the #5801 factory-time ranking).
# Purchase is exercised through model logic — scopes, validations, fees,
# lifecycle, charge processing. HTTP-touching paths (Stripe/PayPal/Braintree)
# replay the existing RSpec cassettes via the VCR bridge (#5938), reusing the
# create_credit_card/build_chargeable helpers the subscription port landed.
#
# The RSpec file nests describe/context/it; this suite uses flat `test "..."`
# methods with per-section setup helpers, matching subscription_test.
class PurchaseTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    ensure_gumroad_merchant_accounts
    # purchase_spec treats every product as Discover-recommendable.
    Link.any_instance.stubs(:recommendable?).returns(true)
  end

  # --- scopes ----------------------------------------------------------------

  test "in_progress returns in-progress purchases and not others" do
    in_progress = create_purchase(purchase_state: "in_progress")
    successful = create_purchase(purchase_state: "successful")
    assert_includes Purchase.in_progress, in_progress
    assert_not_includes Purchase.in_progress, successful
  end

  test "payment_settling returns in-progress purchases the processor has confirmed" do
    settling = create_purchase(purchase_state: "in_progress", stripe_status: "processing")
    assert_includes Purchase.payment_settling, settling
  end

  test "payment_settling excludes abandoned attempts with no processor confirmation" do
    abandoned = create_purchase(purchase_state: "in_progress", stripe_status: nil)
    assert_not_includes Purchase.payment_settling, abandoned
  end

  test "payment_settling excludes purchases in a terminal state even with stripe_status set" do
    failed = create_purchase(purchase_state: "failed", stripe_status: "payment_intent.payment_failed")
    successful = create_purchase(purchase_state: "successful", stripe_status: "charge.succeeded")
    assert_not_includes Purchase.payment_settling, failed
    assert_not_includes Purchase.payment_settling, successful
  end

  test "successful returns successful purchases and not failed ones" do
    successful = create_purchase(purchase_state: "successful")
    failed = create_purchase(purchase_state: "failed")
    assert_includes Purchase.successful, successful
    assert_not_includes Purchase.successful, failed
  end

  test "not_successful returns only unsuccessful purchases" do
    successful = create_purchase(purchase_state: "successful")
    failed = create_purchase(purchase_state: "failed")
    assert_includes Purchase.not_successful, failed
    assert_not_includes Purchase.not_successful, successful
  end

  test "failed returns failed purchases and not successful ones" do
    successful = create_purchase(purchase_state: "successful")
    failed = create_purchase(purchase_state: "failed")
    assert_not_includes Purchase.failed, successful
    assert_includes Purchase.failed, failed
  end

  # --- charge processing (cassette-backed) -----------------------------------

  test "processor_fee_cents gets calculated correctly" do
    VCR.use_cassette("Purchase/processor_fee_cents/gets_calculated_correctly") do
      purchase = create_purchase
      purchase.perceived_price_cents = 100
      purchase.chargeable = build_chargeable
      purchase.process!
      assert_equal 10, purchase.processor_fee_cents
    end
  end

  private
    def ensure_gumroad_merchant_accounts
      MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id) ||
        create_merchant_account(user: nil, charge_processor_merchant_id: "acct_#{unique_suffix}")
      MerchantAccount.gumroad(PaypalChargeProcessor.charge_processor_id) ||
        create_merchant_account_paypal(user: nil, charge_processor_merchant_id: "paypal_#{unique_suffix}")
      MerchantAccount.gumroad(BraintreeChargeProcessor.charge_processor_id) ||
        create_merchant_account(user: nil, charge_processor_id: BraintreeChargeProcessor.charge_processor_id,
                                charge_processor_merchant_id: "braintree_#{unique_suffix}")
    end
end
