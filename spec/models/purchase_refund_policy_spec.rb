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

  describe "product_refund_policy helper methods" do
    let(:product) { create(:product) }
    let(:product_refund_policy) { create(:product_refund_policy, product:) }
    let(:purchase) { create(:purchase, link: product) }

    describe "#product_refund_policy_title" do
      let(:refund_policy) do
        purchase.create_purchase_refund_policy!(
          title: product_refund_policy.title,
          fine_print: product_refund_policy.fine_print
        )
      end

      it "returns the product refund policy title" do
        expect(refund_policy.product_refund_policy_title).to eq product_refund_policy.title
      end
    end

    describe "#different_than_product_refund_policy?" do
      context "when title matches product refund policy title" do
        let(:refund_policy) do
          purchase.create_purchase_refund_policy!(
            title: product_refund_policy.title,
            fine_print: product_refund_policy.fine_print
          )
        end

        it "returns false" do
          expect(refund_policy.different_than_product_refund_policy?).to be false
        end
      end

      context "when title differs from product refund policy title" do
        let(:refund_policy) do
          purchase.create_purchase_refund_policy!(
            title: "Custom Refund Policy",
            fine_print: product_refund_policy.fine_print
          )
        end

        it "returns true" do
          expect(refund_policy.different_than_product_refund_policy?).to be true
        end
      end
    end
  end
end
