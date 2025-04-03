# frozen_string_literal: true

require "spec_helper"

describe Settings::Team::TeamMembershipPolicy do
  subject { described_class }

  let(:accountant_for_seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:marketing_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }
  let(:seller) { create(:named_seller) }
  let(:team_membership_of_other_member) { create(:team_membership, seller:) }

  before do
    create(:team_membership, user: accountant_for_seller, seller:, role: TeamMembership::ROLE_ACCOUNTANT)
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: marketing_for_seller, seller:, role: TeamMembership::ROLE_MARKETING)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :update?, :destroy?, :restore? do
    it "grants access to owner" do
      seller_context = SellerContext.new(user: seller, seller:)
      expect(subject).to permit(seller_context, team_membership_of_other_member)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, team_membership_of_other_member)
    end

    it "denies access to marketing" do
      seller_context = SellerContext.new(user: marketing_for_seller, seller:)
      expect(subject).not_to permit(seller_context, team_membership_of_other_member)
    end

    it "denies access to support" do
      seller_context = SellerContext.new(user: support_for_seller, seller:)
      expect(subject).not_to permit(seller_context, team_membership_of_other_member)
    end
  end

  permissions :destroy? do
    before do
      team_membership_of_other_member.update(role: TeamMembership::ROLE_MARKETING)
    end

    it "grants access to other member" do
      seller_context = SellerContext.new(user: team_membership_of_other_member.user, seller:)
      expect(subject).to permit(seller_context, team_membership_of_other_member)
    end
  end
end
