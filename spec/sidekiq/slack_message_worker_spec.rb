# frozen_string_literal: true

require "spec_helper"

describe SlackMessageWorker do
  describe "#perform" do
    let(:room_name) { "test" }
    let(:sender) { "Test Service" }
    let(:message_text) { "Test notification message" }
    let(:color) { "green" }
    let(:options) { {} }
    let(:recipient_email) { "notifications@gumroad.com" }
    let(:slack_webhook_url) { "https://hooks.slack.com/test" }

    before do
      stub_const("SlackMessageWorker::SLACK_WEBHOOK_URL", slack_webhook_url)
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return(recipient_email)
      allow(GlobalConfig).to receive(:get).with("MAILER_HEADERS_ENCRYPTION_KEY_V1").and_return("test_encryption_key_v1")
      stub_request(:post, slack_webhook_url)
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(false)
    end

    it "sends email notification" do
      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original

      described_class.new.perform(room_name, sender, message_text, color, options)
    end

    it "sends both Slack and email notifications when feature flag is disabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(false)
      
      expect_any_instance_of(Slack::Notifier).to receive(:ping)
      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original

      described_class.new.perform(room_name, sender, message_text, color, options)
    end

    it "skips Slack notification when feature flag is enabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(true)

      expect_any_instance_of(Slack::Notifier).not_to receive(:ping)

      described_class.new.perform(room_name, sender, message_text, color, options)
    end

    it "still sends email when feature flag is enabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(true)

      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original

      described_class.new.perform(room_name, sender, message_text, color, options)
    end

    it "does not raise error if email fails" do
      allow(NotificationMailer).to receive(:slack_notification).and_raise(StandardError.new("Email error"))

      expect { described_class.new.perform(room_name, sender, message_text, color, options) }.not_to raise_error
    end

    it "logs error if email fails" do
      allow(NotificationMailer).to receive(:slack_notification).and_raise(StandardError.new("Email error"))
      allow(Rails.logger).to receive(:error)

      described_class.new.perform(room_name, sender, message_text, color, options)

      expect(Rails.logger).to have_received(:error).with("Failed to send notification email: Email error")
    end

    it "passes attachments to email notification" do
      options_with_attachments = {
        "attachments" => [
          { "title" => "Report", "text" => "Details" }
        ]
      }

      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options_with_attachments)
        .and_call_original

      described_class.new.perform(room_name, sender, message_text, color, options_with_attachments)
    end
  end
end
