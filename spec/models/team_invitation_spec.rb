# frozen_string_literal: true

require "spec_helper"

describe TeamInvitation do
  let(:seller) { create(:named_seller) }

  describe "validations" do
    it "requires seller, email, role to be present" do
      team_invitation = TeamInvitation.new
      expect(team_invitation.valid?).to eq(false)
      expect(team_invitation.errors.full_messages).to include("Seller must exist")
      expect(team_invitation.errors.full_messages).to include("Email is invalid")
      expect(team_invitation.errors.full_messages).to include("Role is not included in the list")
    end

    it "validates uniqueness for seller and email when the record is alive" do
      team_invitation = create(:team_invitation, seller:)
      team_invitation_dupe = team_invitation.dup
      expect(team_invitation_dupe.valid?).to eq(false)
      expect(team_invitation_dupe.errors.full_messages).to include("Email has already been invited")
    end

    it "validates email against active team membership" do
      team_membership = create(:team_membership, seller:)
      team_invitation = TeamInvitation.new(seller:, role: TeamMembership::ROLE_ADMIN, email: team_membership.user.email)
      expect(team_invitation.valid?).to eq(false)
      expect(team_invitation.errors.full_messages).to include("Email is associated with an existing team member")
    end

    it "validates email against owner's email" do
      team_invitation = TeamInvitation.new(seller:, role: TeamMembership::ROLE_ADMIN, email: seller.email)
      expect(team_invitation.valid?).to eq(false)
      expect(team_invitation.errors.full_messages).to include("Email is associated with an existing team member")
    end

    it "sanitizes email" do
      team_invitation = TeamInvitation.new(email: " Member@Example.com  ")
      team_invitation.validate
      expect(team_invitation.email).to eq("member@example.com")
    end

    context "with deleted record" do
      let(:team_invitation) { create(:team_invitation, seller:) }

      before do
        team_invitation.update_as_deleted!
      end

      it "allows creating a new record with same email" do
        expect do
          create(:team_invitation, seller:, role: TeamMembership::ROLE_ADMIN, email: team_invitation.email)
        end.to change { TeamInvitation.count }.by(1)
      end
    end
  end

  describe "#expired?" do
    let(:team_invitation) { create(:team_invitation, seller:) }

    it "returns apropriate boolean value" do
      expect(team_invitation.expired?).to be(false)
      team_invitation.expires_at = Time.current
      expect(team_invitation.expired?).to be(true)
    end
  end

  describe "#from_gumroad_account?" do
    context "when seller.gumroad_account? is false" do
      let(:team_invitation) { create(:team_invitation, seller:) }

      it "returns false" do
        expect(team_invitation.from_gumroad_account?).to be(false)
      end
    end

    context "when seller.gumroad_account? is true" do
      let(:seller) { create(:named_seller, email: ApplicationMailer::ADMIN_EMAIL) }
      let(:team_invitation) { create(:team_invitation, seller:) }

      it "returns true" do
        expect(team_invitation.from_gumroad_account?).to be(true)
      end
    end
  end
end
