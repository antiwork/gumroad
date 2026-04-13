# frozen_string_literal: true

require "spec_helper"

describe InternalNotificationWorker do
  describe "#perform" do
    it "sends an email via InternalNotificationMailer" do
      mailer = double("mailer")
      expect(InternalNotificationMailer).to receive(:notify).with(
        room_name: "payments",
        sender: "Test Sender",
        message_text: "Test message",
        attachments_data: []
      ).and_return(mailer)
      expect(mailer).to receive(:deliver_now)

      described_class.new.perform("payments", "Test Sender", "Test message", "green")
    end

    it "passes attachments from options" do
      attachments = [{ "fallback" => "Attachment text", "text" => "Details" }]
      mailer = double("mailer")
      expect(InternalNotificationMailer).to receive(:notify).with(
        room_name: "announcements",
        sender: "Reporter",
        message_text: "Report ready",
        attachments_data: attachments
      ).and_return(mailer)
      expect(mailer).to receive(:deliver_now)

      described_class.new.perform("announcements", "Reporter", "Report ready", "gray", { "attachments" => attachments })
    end
  end
end
