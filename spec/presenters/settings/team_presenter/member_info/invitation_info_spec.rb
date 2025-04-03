# frozen_string_literal: true

require "spec_helper"

describe Settings::TeamPresenter::MemberInfo::InvitationInfo do
  let(:seller) { create(:named_seller) }
  let(:user) { create(:user) }
  let(:email) { "joe@example.com" }
  let(:pundit_user) { SellerContext.new(user:, seller:) }
  let!(:team_invitation) { create(:team_invitation, seller:, email:, role: TeamMembership::ROLE_ADMIN, expires_at: 1.minute.ago) }

  describe ".build_invitation_info" do
    context "with user signed in as admin for seller" do
      let!(:team_membership) { create(:team_membership, seller:, user:, role: TeamMembership::ROLE_ADMIN) }

      it "returns correct info" do
        info = Settings::TeamPresenter::MemberInfo.build_invitation_info(pundit_user:, team_invitation:)
        expect(info.to_hash).to eq({
                                     type: "invitation",
                                     id: team_invitation.external_id,
                                     role: "admin",
                                     name: "",
                                     email:,
                                     avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                                     is_expired: true,
                                     options: [
                                       {
                                         id: "accountant",
                                         label: "Accountant"
                                       },
                                       {
                                         id: "admin",
                                         label: "Admin"
                                       },
                                       {
                                         id: "marketing",
                                         label: "Marketing"
                                       },
                                       {
                                         id: "support",
                                         label: "Support"
                                       },
                                       {
                                         id: "resend_invitation",
                                         label: "Resend invitation"
                                       },
                                       {
                                         id: "remove_from_team",
                                         label: "Remove from team"
                                       }
                                     ],
                                     leave_team_option: nil
                                   })
      end

      context "when invitation has wip role" do
        before do
          # TODO: update once marketing role is no longer WIP
          team_invitation.update_attribute(:role, TeamMembership::ROLE_MARKETING)
        end

        it "includes wip role in options" do
          info = Settings::TeamPresenter::MemberInfo.build_invitation_info(pundit_user:, team_invitation:)
          expect(info.to_hash).to eq({
                                       type: "invitation",
                                       id: team_invitation.external_id,
                                       role: "marketing",
                                       name: "",
                                       email:,
                                       avatar_url: ActionController::Base.helpers.asset_url("gumroad-default-avatar-5.png"),
                                       is_expired: true,
                                       options: [
                                         {
                                           id: "accountant",
                                           label: "Accountant"
                                         },
                                         {
                                           id: "admin",
                                           label: "Admin"
                                         },
                                         {
                                           id: "marketing",
                                           label: "Marketing"
                                         },
                                         {
                                           id: "support",
                                           label: "Support"
                                         },
                                         {
                                           id: "resend_invitation",
                                           label: "Resend invitation"
                                         },
                                         {
                                           id: "remove_from_team",
                                           label: "Remove from team"
                                         }
                                       ],
                                       leave_team_option: nil
                                     })
        end
      end
    end

    context "with user signed in as marketing for seller" do
      let(:user_with_marketing_role) { create(:user) }
      let!(:team_membership) { create(:team_membership, seller:, user: user_with_marketing_role, role: TeamMembership::ROLE_MARKETING) }
      let(:pundit_user) { SellerContext.new(user: user_with_marketing_role, seller:) }

      it "includes only the current role" do
        info = Settings::TeamPresenter::MemberInfo.build_invitation_info(pundit_user:, team_invitation:)
        expect(info.to_hash[:options]).to eq(
          [
            {
              id: "admin",
              label: "Admin"
            }
          ]
        )
      end
    end
  end
end
