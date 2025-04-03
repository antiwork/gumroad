# frozen_string_literal: true

require "spec_helper"

describe WishlistProductPolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }
  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:wishlist_product) { create(:wishlist_product, wishlist: create(:wishlist, user: seller)) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :index?, :destroy? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, wishlist_product)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to_not permit(seller_context, wishlist_product)
    end

    it "denies access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to_not permit(seller_context, wishlist_product)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to_not permit(seller_context, wishlist_product)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to_not permit(seller_context, wishlist_product)
    end
  end

  permissions :destroy? do
    let(:wishlist_product) { create(:wishlist_product, wishlist: create(:wishlist, user: create(:user))) }

    it "denies access to another user's wishlist product" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to_not permit(seller_context, wishlist_product)
    end
  end
end
