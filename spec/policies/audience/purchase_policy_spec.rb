# frozen_string_literal: true

require "spec_helper"

describe Audience::PurchasePolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :index? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end

    it "grants access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end
  end

  permissions :update?, :refund?, :change_can_contact?, :cancel_preorder_by_seller?, :mark_as_shipped?, :manage_license? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, Follower)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Purchase)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, Follower)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Follower)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end
  end

  permissions :revoke_access? do
    let(:purchase) { create(:purchase) }
    let(:seller_context) { SellerContext.new(user: seller, seller:) }

    it "grants access to owner" do
      expect(subject).to permit(seller_context, purchase)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Purchase)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, purchase)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, purchase)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, purchase)
    end

    context "when access has been revoked" do
      before do
        purchase.update!(is_access_revoked: true)
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, purchase)
      end
    end

    context "when purchase is refunded" do
      before do
        purchase.update!(stripe_refunded: true)
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, purchase)
      end
    end

    context "when product is physical" do
      let(:purchase) { create(:physical_purchase, link: create(:physical_product)) }

      it "denies access" do
        expect(subject).not_to permit(seller_context, purchase)
      end
    end

    context "when purchase is subscription" do
      let(:purchase) { create(:membership_purchase) }

      it "denies access" do
        expect(subject).not_to permit(seller_context, purchase)
      end
    end
  end

  permissions :undo_revoke_access? do
    let(:purchase) { create(:purchase, is_access_revoked: true) }
    let(:seller_context) { SellerContext.new(user: seller, seller:) }

    it "grants access to owner" do
      expect(subject).to permit(seller_context, purchase)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Purchase)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, purchase)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, purchase)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, Purchase)
    end

    context "when access has not been revoked" do
      before do
        purchase.update!(is_access_revoked: false)
      end

      it "denies access" do
        expect(subject).not_to permit(seller_context, purchase)
      end
    end
  end
end
