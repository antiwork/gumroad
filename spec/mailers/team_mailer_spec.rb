# frozen_string_literal: true

require "spec_helper"

describe TeamMailer do
  let(:seller) { create(:named_seller) }

  describe "#invite" do
    let(:email) { "member@example.com" }
    let(:team_invitation) { create(:team_invitation, seller:, email:) }
    subject(:mail) { described_class.invite(team_invitation) }

    %w[suspended_for_fraud suspended_for_tos_violation deleted].each do |state|
      it "does not deliver a queued invitation after the seller becomes #{state}" do
        expect do
          mail.deliver_later
        end.to have_enqueued_mail(described_class, :invite).with(team_invitation)
        seller.update!(state == "deleted" ? { deleted_at: Time.current } : { user_risk_state: state })

        expect do
          perform_enqueued_jobs(only: described_class.delivery_job)
        end.not_to change(ActionMailer::Base.deliveries, :count)
      end
    end

    [
      '"Synthetic notice" <member@example.com>, "sink"@example.net',
      '"Synthetic notice" <member@example.com>',
      "Members:member@example.com;",
      '"member"@"sink"@example.com'
    ].each do |invalid_email|
      it "does not deliver a queued legacy invitation to #{invalid_email.inspect}" do
        team_invitation.update_columns(email: invalid_email)
        mail.deliver_later

        expect do
          perform_enqueued_jobs(only: described_class.delivery_job)
        end.not_to change(ActionMailer::Base.deliveries, :count)
      end
    end

    context "with a quoted local-part mailbox" do
      let(:email) { '"member,one"@example.com' }

      it "delivers a queued invitation with exactly one SMTP envelope recipient" do
        mail.deliver_later

        expect do
          perform_enqueued_jobs(only: described_class.delivery_job)
        end.to change(ActionMailer::Base.deliveries, :count).by(1)

        delivered_mail = ActionMailer::Base.deliveries.last
        expect(delivered_mail.to).to eq([email])
        expect(delivered_mail.smtp_envelope_to).to eq([email])
        expect(delivered_mail[:to].addrs.first.display_name).to be_nil
      end
    end

    it "delivers a queued invitation from an active seller" do
      mail.deliver_later
      expect do
        perform_enqueued_jobs(only: described_class.delivery_job)
      end.to change(ActionMailer::Base.deliveries, :count).by(1)
      expect(ActionMailer::Base.deliveries.last.to).to eq([email])
      expect(ActionMailer::Base.deliveries.last.smtp_envelope_to).to eq([email])
    end

    %i[deleted_at accepted_at expires_at].each do |attribute|
      it "does not deliver a queued invitation after #{attribute} changes" do
        mail.deliver_later
        team_invitation.update!(attribute => 1.second.ago)

        expect do
          perform_enqueued_jobs(only: described_class.delivery_job)
        end.not_to change(ActionMailer::Base.deliveries, :count)
      end
    end

    it "does not deliver a queued invitation once the seller takes the recipient address" do
      mail.deliver_later
      seller.update_columns(email:)

      expect do
        perform_enqueued_jobs(only: described_class.delivery_job)
      end.not_to change(ActionMailer::Base.deliveries, :count)
    end

    it "still builds an invitation when the seller has no email on file" do
      User.where(id: seller.id).update_all(email: nil)

      expect(mail.message).not_to be_a(ActionMailer::Base::NullMail)
    end

    it "refreshes a cached seller from the primary before building an invitation" do
      team_invitation.seller
      User.find(seller.id).update!(user_risk_state: "suspended_for_fraud")
      expect(team_invitation.seller).to be_account_active

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "does not build an invitation when its seller no longer exists" do
      team_invitation
      User.where(id: seller.id).delete_all

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "does not build an invitation that no longer exists" do
      team_invitation.destroy!

      expect(mail.message).to be_a(ActionMailer::Base::NullMail)
    end

    it "excludes seller-controlled content from the invitation" do
      seller.update!(name: "Unrequested charge notice at example.net", username: "billingcallback")

      expect(mail.subject).to eq("Gumroad team invitation")
      expect(mail.body.decoded).not_to include(seller.name, seller.username, seller.email)
      expect(mail.body.decoded).to include("not a purchase receipt or a charge notice")
      expect(mail.body.decoded).to include("If you are not expecting an invitation, please ignore this email.")
      expect(mail.body.decoded).to have_link("Accept invitation", href: accept_settings_team_invitation_url(team_invitation.external_id, email:))
    end

    it "generates email" do
      expect(mail.to).to eq [email]
      expect(mail.subject).to eq("Gumroad team invitation")
      expect(mail.from).to eq [ApplicationMailer::NOREPLY_EMAIL]
      expect(mail.reply_to).to eq [ApplicationMailer::NOREPLY_EMAIL]

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
