# frozen_string_literal: true

require "spec_helper"

describe Settings::SocialConnectionsPolicy do
  subject { described_class }

  let(:seller) { create(:named_seller) }
  let(:admin_for_seller) { create(:user) }

  before do
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
  end

  permissions :show? do
    it "grants access to the owner" do
      expect(subject).to permit(SellerContext.new(user: seller, seller:), nil)
    end

    it "denies access to team members" do
      expect(subject).not_to permit(SellerContext.new(user: admin_for_seller, seller:), nil)
    end
  end
end
