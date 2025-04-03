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
      expect(mail.subject).to eq("Seller has invited you to join seller")
      expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(mail.reply_to).to eq [seller.email]

      expect(mail.body).to include "This invitation will expire in 7 days."
      expect(mail.body).to include "Accept invitation"
      expect(mail.body).to include accept_settings_team_invitation_url(team_invitation.external_id)
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
