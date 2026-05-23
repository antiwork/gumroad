# frozen_string_literal: true

require "test_helper"

class FlowOfFundsTest < ActiveSupport::TestCase
  self.described_class = FlowOfFunds



  context_ FlowOfFunds do
  context_ ".build_simple_flow_of_funds" do
      let(:currency) { Currency::USD }
      let(:amount_cents) { 100_00 }
      let(:flow_of_funds) { described_class.build_simple_flow_of_funds(currency, amount_cents) }

  test "returns a flow of funds object" do
        expect(flow_of_funds).to be_a(FlowOfFunds)
      end

  test "returns a flow of funds object with an issued amount" do
        expect(flow_of_funds.issued_amount.currency).to eq(currency)
        expect(flow_of_funds.issued_amount.cents).to eq(amount_cents)
      end

  test "returns a flow of funds object with a settled amount" do
        expect(flow_of_funds.settled_amount.currency).to eq(currency)
        expect(flow_of_funds.settled_amount.cents).to eq(amount_cents)
      end

  test "returns a flow of funds object with a gumroad amount" do
        expect(flow_of_funds.gumroad_amount.currency).to eq(currency)
        expect(flow_of_funds.gumroad_amount.cents).to eq(amount_cents)
      end

  test "returns a flow of funds object without a merchant account gross amount" do
        expect(flow_of_funds.merchant_account_gross_amount).to be_nil
        expect(flow_of_funds.merchant_account_net_amount).to be_nil
      end
    end
  end
end
