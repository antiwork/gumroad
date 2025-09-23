# frozen_string_literal: true

require "spec_helper"

describe PurchaseRefundPolicy do
  it { is_expected.to have_one(:link).through(:purchase) }
  it { is_expected.to have_one(:product_refund_policy).through(:link) }

  describe "validations" do
    it "validates presence" do
      refund_policy = PurchaseRefundPolicy.new

      expect(refund_policy.valid?).to be false
      expect(refund_policy.errors.details[:purchase].first[:error]).to eq :blank
      expect(refund_policy.errors.details[:title].first[:error]).to eq :blank
    end

    describe "max_refund_period_in_days validation" do
      let(:purchase) { create(:purchase) }

      context "when created after MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON" do
        before do
          travel_to PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON + 1.day
        end

        after do
          travel_back
        end

        it "requires max_refund_period_in_days to be present" do
          refund_policy = build(:purchase_refund_policy, purchase:, title: "30-day money back guarantee", max_refund_period_in_days: nil)

          expect(refund_policy.valid?).to be false
          expect(refund_policy.errors.details[:max_refund_period_in_days].first[:error]).to eq :blank
        end

        it "allows valid max_refund_period_in_days values" do
          refund_policy = build(:purchase_refund_policy, purchase:, title: "30-day money back guarantee", max_refund_period_in_days: 30)

          expect(refund_policy.valid?).to be true
        end
      end

      context "when created before MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON" do
        before do
          travel_to PurchaseRefundPolicy::MAX_REFUND_PERIOD_IN_DAYS_INTRODUCED_ON - 1.day
        end

        after do
          travel_back
        end

        it "does not require max_refund_period_in_days to be present" do
          refund_policy = build(:purchase_refund_policy, purchase:, title: "30-day money back guarantee", max_refund_period_in_days: nil)

          expect(refund_policy.valid?).to be true
        end

        it "allows max_refund_period_in_days to be nil" do
          refund_policy = build(:purchase_refund_policy, purchase:, title: "30-day money back guarantee", max_refund_period_in_days: nil)

          expect(refund_policy.valid?).to be true
        end
      end

      context "when created_at is nil (new record)" do
        it "requires max_refund_period_in_days to be present" do
          refund_policy = build(:purchase_refund_policy, purchase:, title: "30-day money back guarantee", max_refund_period_in_days: nil)

          expect(refund_policy.valid?).to be false
          expect(refund_policy.errors.details[:max_refund_period_in_days].first[:error]).to eq :blank
        end
      end
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


    describe "#different_than_product_refund_policy?" do
      context "when no product refund policy exists" do
        let(:refund_policy) do
          purchase.create_purchase_refund_policy!(
            title: "30-day money back guarantee",
            fine_print: "This is a purchase-level refund policy",
            max_refund_period_in_days: 30
          )
        end

        it "returns true" do
          expect(refund_policy.different_than_product_refund_policy?).to be true
        end
      end

      context "when max_refund_period_in_days is present" do
        let(:product_refund_policy) { create(:product_refund_policy, product:, max_refund_period_in_days: 30) }

        before do
          product.update!(product_refund_policy:)
        end

        context "when max_refund_period_in_days matches product refund policy" do
          let(:refund_policy) do
            purchase.create_purchase_refund_policy!(
              title: "Different title",
              fine_print: "Different fine print",
              max_refund_period_in_days: 30
            )
          end

          it "returns false" do
            expect(refund_policy.different_than_product_refund_policy?).to be false
          end
        end

        context "when max_refund_period_in_days differs from product refund policy" do
          let(:refund_policy) do
            purchase.create_purchase_refund_policy!(
              title: "Same title",
              fine_print: "Same fine print",
              max_refund_period_in_days: 14
            )
          end

          it "returns true" do
            expect(refund_policy.different_than_product_refund_policy?).to be true
          end
        end
      end

      context "when max_refund_period_in_days is not present" do
        let(:product_refund_policy) { create(:product_refund_policy, product:, title: "30-day money back guarantee") }

        before do
          product.update!(product_refund_policy:)
        end

        context "when title matches product refund policy title" do
          let(:refund_policy) do
            build(
              :purchase_refund_policy,
              purchase:,
              title: "30-day money back guarantee",
              fine_print: "Different fine print",
              max_refund_period_in_days: nil
            )
          end

          it "returns false" do
            expect(refund_policy.different_than_product_refund_policy?).to be false
          end
        end

        context "when title differs from product refund policy title" do
          let(:refund_policy) do
            build(
              :purchase_refund_policy,
              purchase:,
              title: "Custom Refund Policy",
              fine_print: "Same fine print",
              max_refund_period_in_days: nil
            )
          end

          it "returns true" do
            expect(refund_policy.different_than_product_refund_policy?).to be true
          end
        end
      end
    end
  end
end
