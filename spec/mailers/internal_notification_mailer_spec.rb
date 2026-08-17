# frozen_string_literal: true

require "spec_helper"

describe InternalNotificationMailer do
  describe "#notify" do
    # Use the "risk" room, which maps to INTERNAL_NOTIFICATION_EMAIL — a recipient
    # that is intentionally distinct from INTERNAL_NOTIFICATION_ALWAYS_CC. This keeps
    # the `to` and `cc` assertions below meaningful even if PAYMENTS_NOTIFICATION_EMAIL
    # and the always-CC address ever resolve to the same value in a shared config.
    subject(:mail) do
      described_class.notify(
        room_name: "risk",
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
      expect(mail.subject).to eq("[test] [risk] VAT Reporting")
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

    context "for the agent_reports room" do
      subject(:mail) do
        described_class.notify(
          room_name: "agent_reports",
          sender: "Blocked established buyers",
          message_text: "report"
        )
      end

      # The room exists to keep autonomously-worked reports out of human inboxes
      # (gumroad-private#2106); pointing it at a human recipient regresses that silently.
      it "delivers to the agent inbox only" do
        expect(mail.to).to eq([INTERNAL_NOTIFICATION_ALWAYS_CC])
        expect(mail.to).not_to include(INTERNAL_NOTIFICATION_EMAIL)
        expect(mail.cc).to be_nil
      end
    end

    context "with S3 file attachments" do
      subject(:mail) do
        described_class.notify(
          room_name: "risk",
          sender: "India Sales Reporting",
          message_text: "Report ready",
          s3_attachments: [{ "bucket" => "gumroad-reporting", "key" => "sales-tax/in.csv", "filename" => "in.csv" }]
        )
      end

      it "attaches the CSV downloaded from S3" do
        s3_object = double("s3_object")
        allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket, :object).and_return(s3_object)
        allow(s3_object).to receive_message_chain(:get, :body, :read).and_return("id,amount\n1,100\n")

        expect(mail.attachments["in.csv"]).to be_present
        expect(mail.attachments["in.csv"].body.decoded).to eq("id,amount\n1,100\n")
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
