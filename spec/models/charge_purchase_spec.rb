# frozen_string_literal: true

require "spec_helper"

describe ChargePurchase do
  describe "validations" do
    it "validates presence of required attributes" do
      charge_purchase = described_class.new

      expect(charge_purchase).to be_invalid
      expect(charge_purchase.errors.messages).to eq(charge: ["must exist"], purchase: ["must exist"])
    end
  end
end
