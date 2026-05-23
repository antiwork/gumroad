# frozen_string_literal: true

require "test_helper"
require "business/payments/charging/charge_refund_shared_examples"

class ChargeRefundTest < ActiveSupport::TestCase
  self.described_class = ChargeRefund



  context_ ChargeRefund do
    let(:flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 1_00) }

    let(:subject) do
      charge_refund = ChargeRefund.new
      charge_refund.flow_of_funds = flow_of_funds
      charge_refund
    end

    it_behaves_like "a charge refund"
  end
end
