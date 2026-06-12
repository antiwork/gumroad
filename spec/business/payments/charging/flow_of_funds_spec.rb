# frozen_string_literal: true

require "spec_helper"

describe FlowOfFunds do
  describe ".build_simple_flow_of_funds" do
    let(:currency) { Currency::USD }
    let(:amount_cents) { 100_00 }
    let(:flow_of_funds) { described_class.build_simple_flow_of_funds(currency, amount_cents) }

    it "returns a flow of funds object" do
      expect(flow_of_funds).to be_a(FlowOfFunds)
    end

    it "returns a flow of funds object with an issued amount" do
      expect(flow_of_funds.issued_amount.currency).to eq(currency)
      expect(flow_of_funds.issued_amount.cents).to eq(amount_cents)
    end

    it "returns a flow of funds object with a settled amount" do
      expect(flow_of_funds.settled_amount.currency).to eq(currency)
      expect(flow_of_funds.settled_amount.cents).to eq(amount_cents)
    end

    it "returns a flow of funds object with a gumroad amount" do
      expect(flow_of_funds.gumroad_amount.currency).to eq(currency)
      expect(flow_of_funds.gumroad_amount.cents).to eq(amount_cents)
    end

    it "returns a flow of funds object without a merchant account gross amount" do
      expect(flow_of_funds.merchant_account_gross_amount).to be_nil
      expect(flow_of_funds.merchant_account_net_amount).to be_nil
    end
  end

  describe "#to_h" do
    let(:currency) { Currency::USD }
    let(:amount_cents) { 100_00 }
    let(:flow_of_funds) { described_class.build_simple_flow_of_funds(currency, amount_cents) }

    it "serializes each amount under the correct keys" do
      expect(flow_of_funds.to_h).to eq(
        issued_amount: { currency:, cents: amount_cents },
        settled_amount: { currency:, cents: amount_cents },
        gumroad_amount: { currency:, cents: amount_cents },
        merchant_account_gross_amount: {},
        merchant_account_net_amount: {}
      )
    end

    it "serializes nil merchant account amounts as empty hashes" do
      expect(flow_of_funds.to_h[:merchant_account_gross_amount]).to eq({})
      expect(flow_of_funds.to_h[:merchant_account_net_amount]).to eq({})
    end
  end
end

describe FlowOfFunds::Amount do
  describe "#to_h" do
    let(:currency) { Currency::USD }
    let(:cents) { 100_00 }
    let(:amount) { described_class.new(currency:, cents:) }

    it "serializes the currency under the :currency key" do
      expect(amount.to_h).to eq(currency:, cents:)
    end
  end
end
