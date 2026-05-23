# frozen_string_literal: true

require "test_helper"

class UserTeamTest < ActiveSupport::TestCase
  self.described_class = User::Team



  context_ User::Team do
    let(:user) { create(:user) }
    let(:other_seller) { create(:user) }

  context_ "#member_of?" do
  context_ "with self as seller" do
  test "returns true" do
          expect(user.member_of?(user)).to be(true)
        end
      end

  context_ "with other seller as seller" do
  test "returns false without team membership" do
          expect(user.member_of?(other_seller)).to be(false)
        end

  context_ "with deleted team membership" do
          let(:team_membership) { create(:team_membership, user:, seller: other_seller) }

          before do
            team_membership.update_as_deleted!
          end

  test "returns false" do
            expect(user.member_of?(other_seller)).to be(false)
          end
        end

  context_ "with alive team membership" do
          before do
            create(:team_membership, user:, seller: other_seller)
          end

  test "returns true" do
            expect(user.member_of?(other_seller)).to be(true)
          end
        end
      end
    end

  context_ "#role_admin_for?" do
  test "returns true for owner" do
        expect(user.role_admin_for?(user)).to be(true)
      end

  context_ "with alive team membership" do
  context_ "with admin role" do
          before do
            create(:team_membership, user:, seller: other_seller)
          end

  test "returns true for other_seller" do
            expect(user.role_admin_for?(other_seller)).to be(true)
          end
        end

        TeamMembership::ROLES.excluding(TeamMembership::ROLE_OWNER, TeamMembership::ROLE_ADMIN).each do |role|
  context_ "with #{role} role" do
            before do
              create(:team_membership, user:, seller: other_seller, role:)
            end

  test "returns false for other_seller" do
              expect(user.role_admin_for?(other_seller)).to be(false)
            end
          end
        end
      end
    end

    TeamMembership::ROLES.excluding(TeamMembership::ROLE_OWNER, TeamMembership::ROLE_ADMIN).each do |role|
  context_ "#role_#{role}_for?" do
  test "returns true for owner" do
          expect(user.send(:"role_#{role}_for?", user)).to be(true)
        end

  context_ "with alive team membership" do
  context_ "with #{role} role" do
            before do
              create(:team_membership, user:, seller: other_seller, role:)
            end

  test "returns true for other_seller" do
              expect(user.send(:"role_#{role}_for?", other_seller)).to be(true)
            end
          end

  context_ "with admin role" do
            before do
              create(:team_membership, user:, seller: other_seller)
            end

  test "returns false for other_seller" do
              expect(user.send(:"role_#{role}_for?", other_seller)).to be(false)
            end
          end
        end
      end
    end

  context_ "#user_memberships" do
  context_ "with no team_membership records" do
  test "returns empty collection" do
          expect(user.user_memberships.count).to eq(0)
        end
      end

  context_ "with team_membership records" do
        let!(:owner_membership) { TeamMembership.create!(user:, seller: user, role: TeamMembership::ROLE_OWNER) }
        let!(:admin_membership) { TeamMembership.create!(user:, seller: other_seller, role: TeamMembership::ROLE_ADMIN) }
        let!(:other_membership) { TeamMembership.create!(user: other_seller, seller: other_seller, role: TeamMembership::ROLE_OWNER) }

  test "returns correct association" do
          expect(user.reload.user_memberships).to eq([owner_membership, admin_membership])
          expect(owner_membership.user).to eq(user)
          expect(admin_membership.user).to eq(user)
        end
      end
    end

  context_ "#seller_memberships" do
  context_ "with no team_membership records" do
  test "returns empty collection" do
          expect(user.seller_memberships.count).to eq(0)
        end
      end

  context_ "with team_membership records" do
        let!(:owner_membership) { TeamMembership.create!(user:, seller: user, role: TeamMembership::ROLE_OWNER) }
        let!(:admin_membership) { TeamMembership.create!(user:, seller: other_seller, role: TeamMembership::ROLE_ADMIN) }
        let!(:other_membership) { TeamMembership.create!(user: other_seller, seller: other_seller, role: TeamMembership::ROLE_OWNER) }

  test "returns correct association" do
          expect(user.seller_memberships).to eq([owner_membership])
          expect(owner_membership.seller).to eq(user)
        end
      end
    end

  context_ "#create_owner_membership_if_needed!" do
  context_ "when owner membership is missing" do
  test "creates owner membership" do
          expect do
            user.create_owner_membership_if_needed!
          end.to change { user.user_memberships.count }.by(1)

          owner_membership = user.user_memberships.last
          expect(owner_membership.role_owner?).to be(true)
        end
      end

  context_ "when owner membership exists" do
        before do
          user.user_memberships.create!(seller: user, role: TeamMembership::ROLE_OWNER)
        end

  test "doesn't create a record" do
          expect do
            user.create_owner_membership_if_needed!
          end.not_to change { user.user_memberships.count }
        end
      end
    end

  context_ "#gumroad_account?" do
  context_ "when the user's email is not #{ApplicationMailer::ADMIN_EMAIL}" do
  test "returns false" do
          user = create(:user)
          expect(user.gumroad_account?).to be(false)
        end
      end

  context_ "when the user's email is #{ApplicationMailer::ADMIN_EMAIL}" do
  test "returns true" do
          user = create(:user, email: ApplicationMailer::ADMIN_EMAIL)
          expect(user.gumroad_account?).to be(true)
        end
      end
    end
  end
end
