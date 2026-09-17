# frozen_string_literal: true

require "spec_helper"

describe TeamMailer do
  let(:seller) { create(:named_seller) }

  describe "#invite" do
    let(:email) { "member@example.com" }
    let(:team_invitation) { create(:team_invitation, seller:, email:) }
    subject(:mail) { described_class.invite(team_invitation) }

    it "generates email" do
      expect(mail.to).to eq [email]
      expect(mail.subject).to eq("You've been invited to join seller on Gumroad")
      expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(mail.reply_to).to eq [seller.email]

      expect(mail.body).to include "This invitation will expire in 7 days."
      expect(mail.body).to include "Accept invitation"
      expect(mail.body).to include accept_settings_team_invitation_url(team_invitation.external_id)
    end

    # The display name is the inviter's own text. A ring put a fake bank charge and a callback number in it and
    # let this mailer carry it to 504k strangers (gp#2762), so the name never reaches the subject and only reaches
    # the body once the seller has been reviewed.
    context "when the seller has not been marked compliant" do
      let(:seller) { create(:named_seller, name: "$474.55 Charged your Bank for GeekSquad renewal. Call +1 (805) 387-8471 now") }

      it "identifies the inviter by email and keeps the name out of the subject and body" do
        expect(mail.subject).to eq("You've been invited to join seller on Gumroad")
        expect(mail.subject).not_to include "GeekSquad"
        expect(mail.body.encoded).not_to include "GeekSquad"
        expect(mail.body.encoded).to include "#{seller.email} has invited you to join the team at"
      end
    end

    context "when the seller is compliant and active" do
      let(:seller) { create(:named_seller, user_risk_state: "compliant") }

      it "shows the display name in the body but not the subject" do
        expect(mail.subject).to eq("You've been invited to join seller on Gumroad")
        expect(mail.body.encoded).to include "Seller (#{seller.email}) has invited you to join the team at"
      end
    end

    context "when a compliant seller has since been suspended" do
      let(:seller) { create(:named_seller, user_risk_state: "compliant", name: "Still Compliant On Paper") }

      before { seller.update_column(:user_risk_state, "suspended_for_tos_violation") }

      it "falls back to the email" do
        expect(mail.body.encoded).not_to include "Still Compliant On Paper"
        expect(mail.body.encoded).to include "#{seller.email} has invited you to join the team at"
      end
    end
  end

  describe "#invitation_accepted" do
    let(:user) { create(:user, :without_username) }
    let(:team_membership) { create(:team_membership, seller:, user:) }
    subject(:mail) { described_class.invitation_accepted(team_membership) }

    it "generates email" do
      expect(mail.to).to eq [seller.email]
      expect(mail.subject).to eq("#{user.email} has accepted your invitation")
      expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(mail.reply_to).to eq [user.email]

      expect(mail.body).to include "#{user.email} joined the team at seller as Admin"
      expect(mail.body).to include "Manage your team settings"
      expect(mail.body).to include settings_team_url
    end
  end
end
