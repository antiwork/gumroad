# frozen_string_literal: true

require "spec_helper"

describe InternalNotificationMailer do
  describe "#notify" do
    # Payments is finance@, always-CC is gumclaw@ — distinct, so To vs Cc is meaningful.
    # Risk/ops rooms now also default to gumclaw (never hi@), so they cannot be used
    # to assert a distinct CC.
    subject(:mail) do
      described_class.notify(
        room_name: "payments",
        sender: "VAT Reporting",
        message_text: "VAT report generated successfully."
      )
    end

    it "sends to the configured email for the room" do
      expect(mail.to).to eq([PAYMENTS_NOTIFICATION_EMAIL])
    end

    it "CCs Gumclaw on every notification in addition to the room recipient" do
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

    context "for the agent_reports room" do
      subject(:mail) do
        described_class.notify(
          room_name: "agent_reports",
          sender: "Blocked established buyers",
          message_text: "report"
        )
      end

      # Agent-only inbox. Risk/ops also go to gumclaw now (never hi@), so the
      # regression to watch is leaking to finance@ or hi@.
      it "delivers to the agent inbox only" do
        expect(mail.to).to eq([INTERNAL_NOTIFICATION_ALWAYS_CC])
        expect(mail.to).not_to include(PAYMENTS_NOTIFICATION_EMAIL)
        expect(mail.to).not_to include("hi@gumroad.com")
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
        allow(s3_object).to receive(:content_length).and_return(20)
        allow(s3_object).to receive_message_chain(:get, :body, :read).and_return("id,amount\n1,100\n")

        expect(mail.attachments["in.csv"]).to be_present
        expect(mail.attachments["in.csv"].body.decoded).to eq("id,amount\n1,100\n")
      end

      it "skips attaching a CSV larger than the MIME cap" do
        s3_object = double("s3_object")
        allow(Aws::S3::Resource).to receive_message_chain(:new, :bucket, :object).and_return(s3_object)
        allow(s3_object).to receive(:content_length).and_return(described_class::MAX_S3_ATTACHMENT_BYTES + 1)

        expect(s3_object).not_to receive(:get)
        expect(mail.attachments).to be_empty
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
