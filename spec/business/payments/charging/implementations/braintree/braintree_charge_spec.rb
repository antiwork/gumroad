# frozen_string_literal: true

require "spec_helper"

describe BraintreeCharge, :vcr do
  describe "charge without fingerprint or card details" do
    before do
      chargeable_element = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
      chargeable_element.prepare!

      params = {
        merchant_account_id: BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS,
        amount: 100_00 / 100.0,
        customer_id: chargeable_element.reusable_token!(nil),
        options: {
          submit_for_settlement: true
        }
      }
      @transaction = Braintree::Transaction.sale!(params)

      @transaction_id = @transaction.id
    end

    it "retrieves the card information for a paypal account successfully" do
      test_transaction = Braintree::Transaction.find(@transaction_id)
      test_charge = BraintreeCharge.new(test_transaction, load_extra_details: true)

      expect(test_charge.card_instance_id).to eq(test_transaction.credit_card_details.token)
      expect(test_charge.card_last4).to eq(nil)
      expect(test_charge.card_type).to eq(CardType::UNKNOWN)
      expect(test_charge.card_number_length).to eq(nil)
      expect(test_charge.card_expiry_month).to eq(nil)
      expect(test_charge.card_expiry_year).to eq(nil)
      expect(test_charge.card_country).to eq(nil)

      expect(test_charge.card_zip_code).to eq(nil)
      expect(test_charge.card_fingerprint).to eq("paypal_jane.doe@example.com")
    end

    it "has a simple flow of funds" do
      charge = BraintreeCharge.new(@transaction, load_extra_details: false)
      expect(charge.flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(charge.flow_of_funds.issued_amount.cents).to eq(100_00)
      expect(charge.flow_of_funds.settled_amount.currency).to eq(Currency::USD)
      expect(charge.flow_of_funds.settled_amount.cents).to eq(100_00)
      expect(charge.flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(charge.flow_of_funds.gumroad_amount.cents).to eq(100_00)
      expect(charge.flow_of_funds.merchant_account_gross_amount).to be_nil
      expect(charge.flow_of_funds.merchant_account_net_amount).to be_nil
    end
  end
end
