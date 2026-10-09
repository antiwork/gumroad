# frozen_string_literal: true

require "spec_helper"

describe PiracyReportPolicy do
  subject { described_class }

  let(:seller) { create(:user) }
  let(:admin_for_seller) { create(:user) }
  let(:support_for_seller) { create(:user) }

  before do
    create(:team_membership, user: admin_for_seller, seller:, role: TeamMembership::ROLE_ADMIN)
    create(:team_membership, user: support_for_seller, seller:, role: TeamMembership::ROLE_SUPPORT)
  end

  permissions :tab? do
    it "grants the owner and admins once the seller filed a report" do
      expect(subject).not_to permit(SellerContext.new(user: seller, seller:), PiracyReport)

      create(:piracy_report, seller:)

      expect(subject).to permit(SellerContext.new(user: seller, seller:), PiracyReport)
      expect(subject).to permit(SellerContext.new(user: admin_for_seller, seller:), PiracyReport)
    end

    it "denies team members who cannot open the list" do
      create(:piracy_report, seller:)

      expect(subject).not_to permit(SellerContext.new(user: support_for_seller, seller:), PiracyReport)
    end
  end
end
