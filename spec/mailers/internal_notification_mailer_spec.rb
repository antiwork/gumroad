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
    end
  end
end
