# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundPolicy do
  describe "validations" do
    it "validates presence" do
      refund_policy = PurchaseRefundPolicy.new

      expect(refund_policy.valid?).to be false
      expect(refund_policy.errors.details[:purchase].first[:error]).to eq :blank
      expect(refund_policy.errors.details[:title].first[:error]).to eq :blank
    end
  end

  describe "stripped_fields" do
    let(:purchase) { create(:purchase) }

    it "strips leading and trailing spaces for title and fine_print" do
      refund_policy = PurchaseRefundPolicy.new(purchase:, title: "  Refund policy  ", fine_print: "  This is a product-level refund policy  ")
      refund_policy.validate

      expect(refund_policy.title).to eq "Refund policy"
      expect(refund_policy.fine_print).to eq "This is a product-level refund policy"
    end

    it "nullifies fine_print" do
      refund_policy = create(:product_refund_policy, fine_print: "")

      expect(refund_policy.fine_print).to be_nil
    end
  end
end
