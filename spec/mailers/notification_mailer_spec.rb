# frozen_string_literal: true

require "spec_helper"

describe NotificationMailer do
  describe "#slack_notification" do
    let(:room_name) { "accounting" }
    let(:sender) { "Test Service" }
    let(:message_text) { "Multi-state summary report for 2025-10 is ready\nReport URL: https://example.com/report" }
    let(:recipient_email) { "notifications@gumroad.com" }

    before do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return(recipient_email)
      allow(GlobalConfig).to receive(:get).with("MAILER_HEADERS_ENCRYPTION_KEY_V1").and_return("test_encryption_key_v1")
    end

    it "sends email with correct subject format" do
      mail = NotificationMailer.slack_notification(room_name, sender, message_text)
      expect(mail.subject).to eq("[test] [Gumroad Notifications][Accounting] Multi-state summary report for 2025-10 is ready")
    end

    it "sends email to configured recipient from NOTIFICATIONS_EMAIL constant" do
      mail = NotificationMailer.slack_notification(room_name, sender, message_text)
      expect(mail.to).to eq([NotificationMailer::NOTIFICATIONS_EMAIL])
    end

    it "sends email from noreply address" do
      mail = NotificationMailer.slack_notification(room_name, sender, message_text)
      expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
    end

    it "includes sender and message in email body" do
      mail = NotificationMailer.slack_notification(room_name, sender, message_text)
      expect(mail.body.encoded).to include(sender)
      expect(mail.body.encoded).to include("Multi-state summary report for 2025-10 is ready")
      expect(mail.body.encoded).to include("Report URL: https://example.com/report")
    end

    it "capitalizes room name in subject" do
      mail = NotificationMailer.slack_notification("payments", sender, message_text)
      expect(mail.subject).to include("[Payments]")
    end

    it "handles multi-line messages by using first line in subject" do
      multi_line_message = "PayPal balance needs attention\nDetails: $200,000.00 required\nAction needed"
      mail = NotificationMailer.slack_notification(room_name, sender, multi_line_message)
      expect(mail.subject).to eq("[test] [Gumroad Notifications][Accounting] PayPal balance needs attention")
    end

    it "includes attachments in email body" do
      options = {
        "attachments" => [
          { "title" => "Report Details", "text" => "Additional information" }
        ]
      }
      mail = NotificationMailer.slack_notification(room_name, sender, message_text, options)
      expect(mail.body.encoded).to include("Report Details")
      expect(mail.body.encoded).to include("Additional information")
    end
  end
end
