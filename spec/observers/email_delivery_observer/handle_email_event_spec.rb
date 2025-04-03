# frozen_string_literal: true

require "spec_helper"

describe EmailDeliveryObserver::HandleEmailEvent do
  let(:user) { create(:user, email: "user@example.com") }
  let(:email_digest) { Digest::SHA1.hexdigest(user.email).first(12) }

  describe ".perform" do
    it "logs email sent event" do
      timestamp = Time.current
      travel_to timestamp do
        expect do
          TwoFactorAuthenticationMailer.authentication_token(user.id).deliver_now
        end.to change { EmailEvent.count }.by(1)

        record = EmailEvent.find_by(email_digest:)
        expect(record.sent_emails_count).to eq 1
        expect(record.unopened_emails_count).to eq 1
        expect(record.last_email_sent_at.to_i).to eq timestamp.to_i
        expect(record.first_unopened_email_sent_at.to_i).to eq timestamp.to_i
      end
    end
  end
end
