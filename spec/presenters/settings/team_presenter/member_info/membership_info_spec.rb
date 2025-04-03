# frozen_string_literal: true

require "spec_helper"

describe Settings::TeamPresenter::MemberInfo::MembershipInfo do
  let(:seller) { create(:named_seller) }
  let(:user) { create(:user) }
  let(:pundit_user) { SellerContext.new(user:, seller:) }

  describe ".build_membership_info" do
    let!(:team_membership) { create(:team_membership, seller:, user:, role: TeamMembership::ROLE_ADMIN) }

    context "with user signed in as admin for seller" do
      it "returns correct info" do
        info = Settings::TeamPresenter::MemberInfo.build_membership_info(pundit_user:, team_membership:)
        expect(info.to_hash).to eq({
                                     type: "membership",
                                     id: team_membership.external_id,
                                     role: TeamMembership::ROLE_ADMIN,
                                     name: user.display_name,
                                     email: user.form_email,
                                     avatar_url: user.avatar_url,
                                     is_expired: false,
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
                                     ],
                                     leave_team_option: {
                                       id: "leave_team",
                                       label: "Leave team"
                                     }
                                   })
      end

      context "with other team membership" do
        let(:other_user) { create(:user) }
        let!(:other_team_membership) { create(:team_membership, seller:, user: other_user, role: TeamMembership::ROLE_ADMIN) }

        it "returns correct info" do
          info = Settings::TeamPresenter::MemberInfo.build_membership_info(pundit_user:, team_membership: other_team_membership)
          expect(info.to_hash).to eq({
                                       type: "membership",
                                       id: other_team_membership.external_id,
                                       role: TeamMembership::ROLE_ADMIN,
                                       name: other_user.display_name,
                                       email: other_user.form_email,
                                       avatar_url: other_user.avatar_url,
                                       is_expired: false,
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
                                           id: "remove_from_team",
                                           label: "Remove from team"
                                         }
                                       ],
                                       leave_team_option: nil
                                     })
        end

        context "when membership has wip role" do
          before do
            # TODO: update once marketing role is no longer WIP
            other_team_membership.update_attribute(:role, TeamMembership::ROLE_MARKETING)
          end

          it "includes wip role in options" do
            info = Settings::TeamPresenter::MemberInfo.build_membership_info(pundit_user:, team_membership: other_team_membership)
            expect(info.to_hash[:options]).to eq([
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
                                                     id: "remove_from_team",
                                                     label: "Remove from team"
                                                   }
                                                 ])
          end
        end
      end
    end

    context "with user signed in as marketing for seller" do
      let(:user_with_marketing_role) { create(:user) }
      let!(:team_membership) { create(:team_membership, seller:, user: user_with_marketing_role, role: TeamMembership::ROLE_MARKETING) }
      let(:pundit_user) { SellerContext.new(user: user_with_marketing_role, seller:) }

      it "includes only current role for options and leave_team_option" do
        info = Settings::TeamPresenter::MemberInfo.build_membership_info(pundit_user:, team_membership:)
        expect(info.to_hash).to eq({
                                     type: "membership",
                                     id: team_membership.external_id,
                                     role: TeamMembership::ROLE_MARKETING,
                                     name: user_with_marketing_role.display_name,
                                     email: user_with_marketing_role.form_email,
                                     avatar_url: user_with_marketing_role.avatar_url,
                                     is_expired: false,
                                     options: [
                                       {
                                         id: "marketing",
                                         label: "Marketing"
                                       }
                                     ],
                                     leave_team_option: {
                                       id: "leave_team",
                                       label: "Leave team"
                                     }
                                   })
      end
    end
  end
end
