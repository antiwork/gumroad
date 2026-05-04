# frozen_string_literal: true

require "spec_helper"

describe Settings::ProfilePolicy do
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

  permissions :show? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "grants access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end
  end

  permissions :update? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end
  end

  permissions :update_username?, :manage_social_connections? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, seller)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "denies access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, seller)
    end
  end

  describe "#permitted_attributes" do
    it "allows owner to update the username" do
      policy = described_class.new(SellerContext.new(user: seller, seller:), seller)
      expect(policy.permitted_attributes).to include(a_hash_including(user: a_collection_including(:username)))
    end

    it "does not allow accountant to update the username" do
      policy = described_class.new(SellerContext.new(user: accountant_for_seller, seller:), seller)
      expect(policy.permitted_attributes).to_not include(a_hash_including(user: a_collection_including(:username)))
    end

    it "does not allow admin to update the username" do
      policy = described_class.new(SellerContext.new(user: admin_for_seller, seller:), seller)
      expect(policy.permitted_attributes).to_not include(a_hash_including(user: a_collection_including(:username)))
    end

    it "does not allow marketing to update the username" do
      policy = described_class.new(SellerContext.new(user: marketing_for_seller, seller:), seller)
      expect(policy.permitted_attributes).to_not include(a_hash_including(user: a_collection_including(:username)))
    end

    it "does not allow support to update the username" do
      policy = described_class.new(SellerContext.new(user: support_for_seller, seller:), seller)
      expect(policy.permitted_attributes).to_not include(a_hash_including(user: a_collection_including(:username)))
    end
  end
end
