# frozen_string_literal: true

require "spec_helper"

describe CommissionPolicy, :vcr do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:commission) { create(:commission) }
  let!(:seller) { commission.deposit_purchase.seller }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :update? do
    context "when the commission belongs to the seller" do
      before do
        allow(commission.deposit_purchase).to receive(:seller).and_return(seller)
      end

      it "graints access to seller" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, commission)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, commission)
      end

      it "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, commission)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, commission)
      end

      it "grants access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).to permit(seller_context, commission)
      end
    end

    context "when the commission belongs to another seller" do
      let!(:other_commission) { create(:commission) }

      it "denies access to seller" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, other_commission)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, other_commission)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, other_commission)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, other_commission)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, other_commission)
      end
    end
  end
end
