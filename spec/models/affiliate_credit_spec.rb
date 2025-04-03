# frozen_string_literal: true

require "spec_helper"

describe AffiliateCredit do
  describe "associations" do
    it { is_expected.to belong_to(:seller).class_name("User").optional(false) }
    it { is_expected.to belong_to(:affiliate_user).class_name("User").optional(false) }
    it { is_expected.to belong_to(:purchase).optional(false) }
    it { is_expected.to belong_to(:link).optional(true) }
    it { is_expected.to belong_to(:affiliate).optional(true) }
    it { is_expected.to belong_to(:oauth_application).optional(true) }
  end

  describe "validations" do
    it { is_expected.to validate_presence_of(:basis_points) }
    it { is_expected.to validate_numericality_of(:basis_points).is_greater_than_or_equal_to(0).is_less_than_or_equal_to(100_00) }

    it "requires an affiliate or oauth application to be present" do
      expect(build(:affiliate_credit, oauth_application: nil, affiliate: nil)).to_not be_valid
      expect(build(:affiliate_credit, oauth_application: build(:oauth_application), affiliate: nil)).to be_valid
      expect(build(:affiliate_credit, oauth_application: nil)).to be_valid
    end
  end

  describe "#amount_partially_refunded_cents" do
    it "returns the sum of amount_cents of affiliate_partial_refunds" do
      affiliate_credit = create(:affiliate_credit)
      expect(affiliate_credit.amount_partially_refunded_cents).to eq(0)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 12)
      create(:affiliate_partial_refund, affiliate_credit:, amount_cents: 34)
      expect(affiliate_credit.reload.amount_partially_refunded_cents).to eq(46)
    end
  end

  describe "#fee_partially_refunded_cents" do
    it "returns the sum of fee_cents of affiliate_partial_refunds" do
      affiliate_credit = create(:affiliate_credit)
      expect(affiliate_credit.fee_partially_refunded_cents).to eq(0)
      create(:affiliate_partial_refund, affiliate_credit:, fee_cents: 12)
      create(:affiliate_partial_refund, affiliate_credit:, fee_cents: 34)
      expect(affiliate_credit.reload.fee_partially_refunded_cents).to eq(46)
    end
  end

  describe "#create!" do
    let(:seller) { create(:user) }
    let(:product) { create(:product, user: seller) }
    let(:affiliate) { create(:direct_affiliate, seller:, affiliate_basis_points: 10_00, apply_to_all_products:) }
    let!(:product_affiliate) { create(:product_affiliate, product:, affiliate:, affiliate_basis_points: product_basis_points) }

    context "when a product commission is set" do
      let(:product_basis_points) { 20_00 }

      context "when affiliate does not apply to all products" do
        let(:apply_to_all_products) { false }
        let(:purchase) do
          create(:purchase,
                 seller:,
                 link: product,
                 purchase_state: "successful",
                 price_cents: product.price_cents,
                 affiliate_credit_cents: 20)
        end

        it "creates an affiliate credit with the correct amount and product commission" do
          affiliate_credit = AffiliateCredit.create!(purchase:, affiliate:, affiliate_amount_cents: 20, affiliate_fee_cents: 5, affiliate_balance: create(:balance))
          expect(affiliate_credit.amount_cents).to eq(20)
          expect(affiliate_credit.fee_cents).to eq(5)
          expect(affiliate_credit.basis_points).to eq(product_basis_points)
        end
      end

      context "when affiliate applies to all products" do
        let(:apply_to_all_products) { true }
        let(:purchase) do
          create(:purchase,
                 seller:,
                 link: product,
                 purchase_state: "successful",
                 price_cents: product.price_cents,
                 affiliate_credit_cents: 10)
        end

        it "creates an affiliate credit with the correct amount and affiliate commission" do
          affiliate_credit = AffiliateCredit.create!(purchase:, affiliate:, affiliate_amount_cents: 10, affiliate_fee_cents: 5, affiliate_balance: create(:balance))
          expect(affiliate_credit.amount_cents).to eq(10)
          expect(affiliate_credit.fee_cents).to eq(5)
          expect(affiliate_credit.basis_points).to eq(affiliate.affiliate_basis_points)
        end
      end
    end

    context "when a product commission is not set" do
      let(:apply_to_all_products) { false }
      let(:product_basis_points) { nil }
      let(:purchase) do
        create(:purchase,
               seller:,
               link: product,
               purchase_state: "successful",
               price_cents: product.price_cents,
               affiliate_credit_cents: 10)
      end

      it "creates an affiliate credit with the correct amount and commission" do
        affiliate_credit = AffiliateCredit.create!(purchase:, affiliate:, affiliate_amount_cents: 10, affiliate_fee_cents: 5, affiliate_balance: create(:balance))
        expect(affiliate_credit.amount_cents).to eq(10)
        expect(affiliate_credit.fee_cents).to eq(5)
        expect(affiliate_credit.basis_points).to eq(affiliate.affiliate_basis_points)
      end
    end
  end
end
