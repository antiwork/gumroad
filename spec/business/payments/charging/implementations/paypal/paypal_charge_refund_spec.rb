# frozen_string_literal: true

require "spec_helper"

describe PaypalChargeRefund, :vcr do
  let(:paypal_api) { PayPal::SDK::Merchant::API.new }

  let(:pre_prepared_paypal_charge_id) do
    # A USD$5 charge, pre-made on Paypal.
    "58409660Y47347418"
  end

  let(:paypal_refund_response) do
    refund_request = paypal_api.build_refund_transaction(TransactionID: pre_prepared_paypal_charge_id, RefundType: PaypalApiRefundType::FULL)
    paypal_api.refund_transaction(refund_request)
  end

  let(:subject) { described_class.new(paypal_refund_response, pre_prepared_paypal_charge_id) }

  describe "#initialize" do
    describe "with a paypal refund response" do
      it "has a charge_processor_id set to 'paypal' and id and charge_id but no flow_of_funds" do
        expect(subject.charge_processor_id).to eq "paypal"
        expect(subject.id).to eq(paypal_refund_response.RefundTransactionID)
        expect(subject.charge_id).to eq(pre_prepared_paypal_charge_id)
        expect(subject.flow_of_funds).to be_nil
      end
    end
  end
end
