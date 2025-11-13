# frozen_string_literal: true

require "spec_helper"

describe NotificationService do
  describe ".send_notification" do
    let(:room_name) { "test" }
    let(:sender) { "Test Service" }
    let(:message_text) { "Test notification message" }
    let(:color) { "green" }
    let(:options) { {} }
    let(:recipient_email) { "notifications@example.com" }
    let(:slack_webhook_url) { "https://hooks.slack.com/test" }

    before do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("SLACK_WEBHOOK_URL").and_return(slack_webhook_url)
      allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return(recipient_email)
      allow(GlobalConfig).to receive(:get).with("MAILER_HEADERS_ENCRYPTION_KEY_V1").and_return("test_encryption_key_v1")
      stub_request(:post, slack_webhook_url)
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(false)
    end

    it "sends both email and Slack notifications by default" do
      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original
      expect_any_instance_of(Slack::Notifier).to receive(:ping)

      described_class.send_notification(room_name, sender, message_text, color, options)
    end

    it "sends email notification" do
      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original

      described_class.send_notification(room_name, sender, message_text, color, options)
    end

    it "sends Slack notification when feature flag is disabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(false)

      expect_any_instance_of(Slack::Notifier).to receive(:ping)

      described_class.send_notification(room_name, sender, message_text, color, options)
    end

    it "skips Slack notification when feature flag is enabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(true)

      expect_any_instance_of(Slack::Notifier).not_to receive(:ping)

      described_class.send_notification(room_name, sender, message_text, color, options)
    end

    it "still sends email when feature flag is enabled" do
      allow(Feature).to receive(:active?).with(:skip_slack_notifications).and_return(true)

      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options)
        .and_call_original

      described_class.send_notification(room_name, sender, message_text, color, options)
    end

    it "does not raise error if email fails" do
      allow(NotificationMailer).to receive(:slack_notification).and_raise(StandardError.new("Email error"))

      expect { described_class.send_notification(room_name, sender, message_text, color, options) }.not_to raise_error
    end

    it "logs error if email fails" do
      allow(NotificationMailer).to receive(:slack_notification).and_raise(StandardError.new("Email error"))
      allow(Rails.logger).to receive(:error)

      described_class.send_notification(room_name, sender, message_text, color, options)

      expect(Rails.logger).to have_received(:error).with("Failed to send notification email: Email error")
    end

    it "passes attachments to both email and Slack" do
      options_with_attachments = {
        "attachments" => [
          { "title" => "Report Details", "text" => "Additional information" }
        ]
      }

      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options_with_attachments)
        .and_call_original

      described_class.send_notification(room_name, sender, message_text, color, options_with_attachments)
    end

    it "handles indifferent access for options with symbol keys" do
      options_with_symbols = {
        attachments: [
          { "title" => "Report", "text" => "Details" }
        ]
      }

      expect(NotificationMailer).to receive(:slack_notification)
        .with(room_name, sender, message_text, options_with_symbols)
        .and_call_original

      expect { described_class.send_notification(room_name, sender, message_text, color, options_with_symbols) }.not_to raise_error
    end

    it "returns nil for invalid room" do
      # Use a room that doesn't exist in CHAT_ROOMS
      # In non-production, room names get converted to "test", so we need to stub a room
      # that will still be invalid after conversion
      stub_const("CHAT_ROOMS", { test: { slack: nil } })

      expect(NotificationMailer).not_to receive(:slack_notification)
      expect_any_instance_of(Slack::Notifier).not_to receive(:ping)

      result = described_class.send_notification(room_name, sender, message_text, color, options)
      expect(result).to be_nil
    end

    it "uses test channel in non-production environments" do
      expect(CHAT_ROOMS[:test][:slack][:channel]).to eq("test")

      described_class.send_notification("accounting", sender, message_text, color, options)
    end
  end
end
