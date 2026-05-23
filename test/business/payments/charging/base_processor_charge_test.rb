# frozen_string_literal: true

require "test_helper"
require "business/payments/charging/charge_shared_examples"

class BaseProcessorChargeTest < ActiveSupport::TestCase
  self.described_class = BaseProcessorCharge



  context_ BaseProcessorCharge do
    let(:flow_of_funds) { FlowOfFunds.build_simple_flow_of_funds(Currency::USD, 1_00) }

    let(:subject) do
      charge = BaseProcessorCharge.new
      charge.flow_of_funds = flow_of_funds
      charge
    end

    it_behaves_like "a base processor charge"
  end
end
