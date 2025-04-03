# frozen_string_literal: true

require "spec_helper"

describe LinkPolicy do
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
      expect(subject).to permit(seller_context, Link)
    end

    it "grants access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end
  end

  permissions :new?, :create?, :show?, :unpublish?, :publish?, :destroy?, :release_preorder? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Link)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, Link)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, Link)
    end
  end

  permissions :edit? do
    let(:team_member) { create(:user, is_team_member: true) }

    it "grants access to team member" do
      seller_context = SellerContext.new(user: team_member, seller: team_member)
      expect(subject).to permit(seller_context, Link)
    end
  end

  permissions :edit?, :update? do
    context "when product belongs to seller" do
      let(:product) { create(:product, user: seller) }
      let(:collaborating_user) { create(:collaborator, seller:, products: [product]).affiliate_user }

      it "grants access to a collaborator" do
        seller_context = SellerContext.new(user: collaborating_user, seller: collaborating_user)
        expect(subject).to permit(seller_context, product)
      end

      it "grants access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).to permit(seller_context, product)
      end

      it "denies accountant to support" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product)
      end

      it "grants access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).to permit(seller_context, product)
      end

      it "grants access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).to permit(seller_context, product)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product)
      end
    end

    context "when product belongs to other user" do
      let(:product_of_other_user) { create(:product) }

      it "denies access to owner" do
        seller_context = SellerContext.new(user: seller, seller:)
        expect(subject).not_to permit(seller_context, product_of_other_user)
      end

      it "denies access to accountant" do
        seller_context = SellerContext.new(user: accountant_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product_of_other_user)
      end

      it "denies access to admin" do
        seller_context = SellerContext.new(user: admin_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product_of_other_user)
      end

      it "denies access to marketing" do
        seller_context = SellerContext.new(user: marketing_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product_of_other_user)
      end

      it "denies access to support" do
        seller_context = SellerContext.new(user: support_for_seller, seller:)
        expect(subject).not_to permit(seller_context, product_of_other_user)
      end
    end
  end
end
