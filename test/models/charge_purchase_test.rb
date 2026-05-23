# frozen_string_literal: true

require "test_helper"

class ChargePurchaseTest < ActiveSupport::TestCase
  self.described_class = ChargePurchase



  context_ ChargePurchase do
  context_ "validations" do
  test "validates presence of required attributes" do
        charge_purchase = described_class.new

        expect(charge_purchase).to be_invalid
        expect(charge_purchase.errors.messages).to eq(charge: ["must exist"], purchase: ["must exist"])
      end
    end
  end
end
