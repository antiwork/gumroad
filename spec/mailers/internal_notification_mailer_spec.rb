# frozen_string_literal: true

require "spec_helper"

describe InternalNotificationMailer do
  describe "#notify" do
    subject(:mail) do
      described_class.notify(
        room_name: "payments",
        sender: "VAT Reporting",
        message_text: "VAT report generated successfully."
      )
    end

    it "sends to the configured email for the room" do
      expect(mail.to).to eq([INTERNAL_NOTIFICATION_EMAIL])
    end

    it "CCs Gumclaw on every notification in addition to the room recipient" do
      # The mailer dedups the CC when it equals the room's own recipient, so this
      # assertion is only meaningful while the two addresses are distinct. Assert the
      # prerequisite explicitly rather than relying on it implicitly.
      expect(INTERNAL_NOTIFICATION_ALWAYS_CC).not_to eq(mail.to.first)
      expect(mail.cc).to eq([INTERNAL_NOTIFICATION_ALWAYS_CC])
    end

    it "sets the subject with room name and sender" do
      expect(mail.subject).to eq("[test] [payments] VAT Reporting")
    end

    it "includes the sender and message in the body" do
      expect(mail.body.encoded).to include("VAT Reporting")
      expect(mail.body.encoded).to include("VAT report generated successfully.")
    end

    context "with attachments" do
      subject(:mail) do
        described_class.notify(
          room_name: "announcements",
          sender: "Report Bot",
          message_text: "Monthly report",
          attachments_data: [{ "fallback" => "Summary data", "text" => "Details here" }]
        )
      end

      it "includes attachment content in the body" do
        expect(mail.body.encoded).to include("Summary data")
        expect(mail.body.encoded).to include("Details here")
      end
    end

    context "when room has no email configured" do
      subject(:mail) do
        described_class.notify(
          room_name: "nonexistent_room",
          sender: "Test",
          message_text: "Should not send"
        )
      end

      it "returns a null mail" do
        expect(mail.to).to be_nil
      end

      it "does not CC Gumclaw when the room has no recipient" do
        expect(mail.cc).to be_nil
      end
    end

    context "when the room recipient IS the always-CC address" do
      before { stub_const("CHAT_ROOMS", CHAT_ROOMS.merge(gumclaw_room: { email: INTERNAL_NOTIFICATION_ALWAYS_CC })) }

      subject(:mail) do
        described_class.notify(
          room_name: "gumclaw_room",
          sender: "Test",
          message_text: "No duplicate"
        )
      end

      it "does not duplicate the address into CC" do
        expect(mail.to).to eq([INTERNAL_NOTIFICATION_ALWAYS_CC])
        expect(mail.cc).to be_nil
      end
    end
  end
end
