# frozen_string_literal: true

require "spec_helper"

describe Checkout::RestartIntentToken do
  let(:buyer) { create(:user) }
  let(:product) { create(:membership_product) }
  let(:lapsed_at) { 1.day.ago }

  def intended?(token, product: self.product, buyer: self.buyer)
    described_class.restart_intended?(token, product:, buyer:, lapsed_at:)
  end

  describe ".restart_intended?" do
    it "accepts a token issued after the latest deactivation" do
      expect(intended?(described_class.issue(product:, buyer:))).to be true
    end

    it "accepts a guest token for a guest checkout" do
      expect(intended?(described_class.issue(product:, buyer: nil), buyer: nil)).to be true
    end

    it "rejects a token issued before the latest deactivation" do
      token = travel_to(2.days.ago) { described_class.issue(product:, buyer:) }

      expect(intended?(token)).to be false
    end

    it "rejects a token past its lifetime" do
      token = described_class.issue(product:, buyer:)

      travel_to(described_class::TTL.from_now + 1.minute) do
        expect(described_class.restart_intended?(token, product:, buyer:, lapsed_at: 1.year.ago)).to be false
      end
    end

    it "rejects a token issued for another product" do
      expect(intended?(described_class.issue(product: create(:membership_product), buyer:))).to be false
    end

    it "rejects a token issued to another buyer, and a guest token used by a signed-in buyer" do
      expect(intended?(described_class.issue(product:, buyer: create(:user)))).to be false
      expect(intended?(described_class.issue(product:, buyer: nil))).to be false
    end

    it "rejects a token issued to a buyer when the checkout has none" do
      expect(intended?(described_class.issue(product:, buyer:), buyer: nil)).to be false
    end

    it "rejects blank, tampered, and foreign-purpose tokens without raising" do
      foreign = Rails.application.message_verifier(:checkout_payment_method_list).generate({ "product_id" => product.id, "buyer_id" => buyer.id, "issued_at" => Time.current.to_f }, purpose: "checkout_payment_method_list")

      [nil, "", "not-a-token", described_class.issue(product:, buyer:).reverse, foreign, 42].each do |token|
        expect(intended?(token)).to be false
      end
    end
  end
end
