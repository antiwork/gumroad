# frozen_string_literal: true

require "spec_helper"

describe Settings::TeamPresenter do
  let(:seller_one) { create(:user) }
  let(:pundit_user) { SellerContext.new(user: seller_one, seller: seller_one) }

  describe "initialize" do
    it "assigns the correct instance variables" do
      presenter = described_class.new(pundit_user:)
      expect(presenter.pundit_user).to eq(pundit_user)
    end
  end

  describe "#member_infos" do
    context "without records" do
      it "returns owner member info only" do
        member_infos = described_class.new(pundit_user:).member_infos
        expect(member_infos.count).to eq(1)
        expect(member_infos.first.class).to eq(Settings::TeamPresenter::MemberInfo::OwnerInfo)
      end
    end

    context "with records" do
      let(:seller_two) { create(:user) }
      let(:seller_three) { create(:user) }

      before do
        # seller_two belonging to seller_one team
        @team_membership = create(:team_membership, user: seller_two, seller: seller_one, role: TeamMembership::ROLE_ADMIN)
        create(:team_membership, user: seller_two, seller: seller_one, role: TeamMembership::ROLE_ADMIN, deleted_at: Time.current)
        @team_invitation = create(:team_invitation, seller: seller_one, role: TeamMembership::ROLE_ADMIN)
        create(:team_invitation, seller: seller_one, role: TeamMembership::ROLE_ADMIN, deleted_at: Time.current)


        # seller_one belonging to seller_three team - not included in member_infos
        create(:team_membership, user: seller_one, seller: seller_three, role: TeamMembership::ROLE_ADMIN)
        create(:team_invitation, seller: seller_three, role: TeamMembership::ROLE_ADMIN)
      end

      it "returns seller_one member infos" do
        member_infos = described_class.new(pundit_user:).member_infos
        expect(member_infos.count).to eq(3)

        expect(member_infos.first.class).to eq(Settings::TeamPresenter::MemberInfo::OwnerInfo)

        membership_info = member_infos.second
        expect(membership_info.class).to eq(Settings::TeamPresenter::MemberInfo::MembershipInfo)
        expect(membership_info.to_hash[:id]).to eq(@team_membership.external_id)

        invitation_info = member_infos.third
        expect(invitation_info.class).to eq(Settings::TeamPresenter::MemberInfo::InvitationInfo)
        expect(invitation_info.to_hash[:id]).to eq(@team_invitation.external_id)
      end
    end
  end
end
