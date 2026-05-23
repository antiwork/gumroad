# frozen_string_literal: true

require "test_helper"

class BraintreeChargeableNonceTest < ActiveSupport::TestCase
  self.described_class = BraintreeChargeableNonce
  self.rspec_metadata = { vcr: true }



  context_ BraintreeChargeableNonce, :vcr do
  context_ "#prepare!" do
  test "throws a validation failure on using an invalid chargeable" do
        expect do
          chargeable = BraintreeChargeableNonce.new("invalid", nil)
          chargeable.prepare!
        end.to raise_exception(ChargeProcessorInvalidRequestError)
      end

  test "throws a validation failure on using an already consumed chargeable" do
        expect do
          chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::Consumed, nil)
          chargeable.prepare!
        end.to raise_exception(ChargeProcessorInvalidRequestError)
      end

  context_ "credit card chargeable" do
  test "accepts a valid chargeable and displays expected card information" do
          chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::Transactable, nil)
          chargeable.prepare!

          expect(chargeable.braintree_customer_id).not_to be(nil)
          expect(chargeable.fingerprint).to eq("9a09e816d246aac4198e616ca18abe6e")
          expect(chargeable.card_type).to eq(CardType::VISA)
          expect(chargeable.last4).to eq("1881")
          expect(chargeable.expiry_month).to eq("12")
          expect(chargeable.expiry_year).to eq("2020")
        end
      end

  context_ "PayPal account chargeable" do
  test "accepts a valid chargeable and displays expected account information" do
          chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
          chargeable.prepare!

          expect(chargeable.braintree_customer_id).not_to be(nil)
          expect(chargeable.fingerprint).to eq("paypal_jane.doe@example.com")
          expect(chargeable.card_type).to eq(CardType::PAYPAL)
          expect(chargeable.last4).to eq(nil)
          expect(chargeable.visual).to eq("jane.doe@example.com")
          expect(chargeable.expiry_month).to eq(nil)
          expect(chargeable.expiry_year).to eq(nil)
        end
      end
    end

  context_ "#charge_processor_id" do
      let(:chargeable) { BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil) }

  test "returns 'stripe'" do
        expect(chargeable.charge_processor_id).to eq "braintree"
      end
    end
  end
end
