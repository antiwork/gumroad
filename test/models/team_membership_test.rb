# frozen_string_literal: true

require "test_helper"

class TeamMembershipTest < ActiveSupport::TestCase
  self.described_class = TeamMembership



  context_ TeamMembership do
  context_ "validations" do
      let(:user) { create(:user) }
      let(:seller) { create(:named_seller) }

  test "requires user, seller, role to be present" do
        team_membership = TeamMembership.new
        expect(team_membership.valid?).to eq(false)
        expect(team_membership.errors.full_messages).to include("User can't be blank")
        expect(team_membership.errors.full_messages).to include("Seller can't be blank")
        expect(team_membership.errors.full_messages).to include("Role is not included in the list")
      end

  test "requires valid role" do
        team_membership = TeamMembership.new(user:, seller:, role: :foo)
        expect(team_membership.valid?).to eq(false)
        expect(team_membership.errors.full_messages).to include("Role is not included in the list")
      end

  test "validates uniqueness for seller and user when record alive" do
        team_membership = create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN)
        team_membership_dupe = team_membership.dup
        expect(team_membership_dupe.valid?).to eq(false)
        expect(team_membership_dupe.errors.full_messages).to include("Seller has already been taken")
      end

  test "validates role_owner_cannot_be_assigned_to_other_users" do
        team_membership = TeamMembership.new(user:, seller:, role: TeamMembership::ROLE_OWNER)
        expect(team_membership.valid?).to eq(false)
        expect(team_membership.errors.full_messages).to include("Seller must match user for owner role")
      end

  test "validates owner_membership_must_exist" do
        team_membership = user.user_memberships.new(seller:, role: TeamMembership::ROLE_ADMIN)
        expect(team_membership.valid?).to eq(false)
        expect(team_membership.errors.full_messages).to include("User requires owner membership to be created first")
      end

  context_ "validate only_owner_role_can_be_assigned_to_natural_owner" do
        TeamMembership::ROLES.excluding(TeamMembership::ROLE_OWNER).each do |role|
  test "#{role} role cannot be assigned to owner" do
            team_membership = user.user_memberships.new(seller: user, role:)
            expect(team_membership.valid?).to eq(false)
            expect(team_membership.errors.full_messages).to include("Role cannot be assigned to owner's membership")
          end
        end
      end

  context_ "with deleted record" do
        let(:team_membership) { create(:team_membership, user:, seller:, role: TeamMembership::ROLE_ADMIN) }

        before do
          team_membership.update_as_deleted!
        end

  test "allows creating a new record" do
          expect do
            user.user_memberships.create!(seller:, role: TeamMembership::ROLE_ADMIN)
          end.to change { TeamMembership.count }.by(1)
        end
      end
    end
  end
end
