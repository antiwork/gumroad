# frozen_string_literal: true

require "spec_helper"

RSpec.describe Purchase do
  describe "email normalization" do
    it "removes invisible characters before validating the buyer email" do
      purchase = build(:purchase, email: "\u200Fbuyer@example.com")

      purchase.valid?

      expect(purchase.email).to eq("buyer@example.com")
    end

    it "does not remove visible spaces from the buyer email" do
      purchase = build(:purchase, email: "buyer@example.com ")

      purchase.valid?

      expect(purchase.email).to eq("buyer@example.com ")
    end
  end
end
