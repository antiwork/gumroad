# frozen_string_literal: true

require "spec_helper"

describe Products::AffiliatedPolicy do
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
      expect(subject).to permit(seller_context, :affiliated)
    end

    it "grants access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).to permit(seller_context, :affiliated)
    end

    it "grants access to admin" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, :affiliated)
    end

    it "grants access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).to permit(seller_context, :affiliated)
    end

    it "grants access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).to permit(seller_context, :affiliated)
    end
  end

  permissions :destroy? do
    let(:affiliate_user) { create(:user) }
    let(:different_user) { create(:user) }
    let(:affiliate) { create(:direct_affiliate, affiliate_user:, seller:) }

    it "grants access when user is the affiliate user" do
      seller_context = SellerContext.new(user: affiliate_user, seller:)
      expect(subject).to permit(seller_context, affiliate)
    end

    it "denies access when user is not the affiliate user" do
      seller_context = SellerContext.new(user: different_user, seller:)
      expect(subject).not_to permit(seller_context, affiliate)
    end

    it "grants access for symbol record (general authorization)" do
      seller_context = SellerContext.new(user: affiliate_user, seller:)
      policy = subject.new(seller_context, :affiliated)
      expect(policy.destroy?).to be true
    end
  end
end
