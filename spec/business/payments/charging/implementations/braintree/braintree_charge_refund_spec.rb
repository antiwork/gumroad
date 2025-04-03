# frozen_string_literal: true

require "spec_helper"

describe BraintreeChargeRefund, :vcr do
  let(:braintree_chargeable) do
    chargeable = BraintreeChargeableNonce.new(Braintree::Test::Nonce::PayPalFuturePayment, nil)
    chargeable.prepare!
    Chargeable.new([chargeable])
  end

  let(:braintree_charge) do
    params = {
      merchant_account_id: BRAINTREE_MERCHANT_ACCOUNT_ID_FOR_SUPPLIERS,
      amount: 100_00 / 100.0,
      customer_id: braintree_chargeable.get_chargeable_for(BraintreeChargeProcessor.charge_processor_id).reusable_token!(nil),
      options: {
        submit_for_settlement: true
      }
    }
    Braintree::Transaction.sale!(params)
  end

  let(:braintree_refund) do
    Braintree::Transaction.refund!(braintree_charge.id)
  end

  let(:subject) { described_class.new(braintree_refund) }

  describe "#initialize" do
    describe "with a braintree refund" do
      it "has a charge_processor_id set to 'braintree'" do
        expect(subject.charge_processor_id).to eq "braintree"
      end

      it "has the #id from the braintree refund" do
        expect(subject.id).to eq(braintree_refund.id)
      end

      it "has the #charge_id from the braintree refund" do
        expect(subject.charge_id).to eq(braintree_refund.refunded_transaction_id)
      end

      it "has the #charge_id from the original braintree charge" do
        expect(subject.charge_id).to eq(braintree_charge.id)
      end
    end
  end

  describe "#flow_of_funds" do
    let(:flow_of_funds) { subject.flow_of_funds }

    it "has a simple flow of funds" do
      expect(flow_of_funds.issued_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.issued_amount.cents).to eq(-100_00)
      expect(flow_of_funds.settled_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.settled_amount.cents).to eq(-100_00)
      expect(flow_of_funds.gumroad_amount.currency).to eq(Currency::USD)
      expect(flow_of_funds.gumroad_amount.cents).to eq(-100_00)
      expect(flow_of_funds.merchant_account_gross_amount).to be_nil
      expect(flow_of_funds.merchant_account_net_amount).to be_nil
    end
  end
end
