# frozen_string_literal: true

require "spec_helper"

describe Products::Affiliated::DirectAffiliatePolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }
  let(:other_creator) { create(:named_user) }
  let(:own_affiliation) { create(:direct_affiliate, affiliate_user: seller, seller: other_creator) }
  let(:someone_elses_affiliation) { create(:direct_affiliate, seller: other_creator) }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :destroy? do
    it "grants access to the affiliate themselves" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, own_affiliation)
    end

    it "grants access to an admin of the affiliate's account" do
      seller_context = SellerContext.new(user: admin_for_seller, seller:)
      expect(subject).to permit(seller_context, own_affiliation)
    end

    it "denies access to an affiliation the account is not the affiliate on" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).not_to permit(seller_context, someone_elses_affiliation)
    end

    it "denies access to accountant" do
      seller_context = SellerContext.new(user: accountant_for_seller, seller:)
      expect(subject).not_to permit(seller_context, own_affiliation)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, own_affiliation)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, own_affiliation)
    end
  end
end
