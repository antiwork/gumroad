# frozen_string_literal: true

require "spec_helper"

describe NotificationMailer do
  describe "#notification" do
    let(:notification_category) { "payments" }
    let(:source) { "VAT Reporting" }
    let(:message_text) { "Q4 2024 VAT report is ready" }
    let(:notifications_email) { "alerts@gumroad.com" }

    context "with basic parameters" do
      let(:mail) do
        described_class.with(
          notification_category:,
          source:,
          message_text:,
          notifications_email:
        ).notification
      end

      it "sends to the correct recipient" do
        expect(mail.to).to eq([notifications_email])
      end

      it "sets the from address" do
        expect(mail.from).to eq([ApplicationMailer::NOREPLY_EMAIL])
      end

      it "includes notification category in subject" do
        expect(mail.subject).to eq("[Gumroad Notifications][Payments] Q4 2024 VAT report is ready")
      end

      it "includes the message text in the body" do
        expect(mail.body.encoded).to include("Q4 2024 VAT report is ready")
      end

      it "includes the source in the body" do
        expect(mail.body.encoded).to include("VAT Reporting")
      end

      it "includes the notification category in the body" do
        expect(mail.body.encoded).to include("Payments")
      end
    end

    context "with attachments" do
      let(:attachments) do
        [
          {
            title: "Report URL",
            text: "https://example.com/reports/q4",
            url: "https://example.com/reports/q4"
          }
        ]
      end

      let(:mail) do
        described_class.with(
          notification_category:,
          source:,
          message_text:,
          attachments:,
          notifications_email:
        ).notification
      end

      it "includes attachment title" do
        expect(mail.body.encoded).to include("Report URL")
      end

      it "includes attachment text" do
        expect(mail.body.encoded).to include("https://example.com/reports/q4")
      end
    end

    context "with array message_text" do
      let(:message_text) { ["Line 1", "Line 2", "Line 3"] }

      let(:mail) do
        described_class.with(
          notification_category:,
          source:,
          message_text:,
          notifications_email:
        ).notification
      end

      it "includes all lines in the body" do
        expect(mail.body.encoded).to include("Line 1")
        expect(mail.body.encoded).to include("Line 2")
        expect(mail.body.encoded).to include("Line 3")
      end

      it "combines lines in the subject" do
        expect(mail.subject).to eq("[Gumroad Notifications][Payments] Line 1 Line 2 Line 3")
      end
    end

    context "with empty message_text" do
      let(:message_text) { "" }

      let(:mail) do
        described_class.with(
          notification_category:,
          source:,
          message_text:,
          notifications_email:
        ).notification
      end

      it "uses default subject suffix" do
        expect(mail.subject).to eq("[Gumroad Notifications][Payments] System notification")
      end
    end

    context "with various notification categories" do
      it "titleizes underscored category names" do
        mail = described_class.with(
          notification_category: "internals_log",
          source:,
          message_text:,
          notifications_email:
        ).notification

        expect(mail.subject).to include("[Internals Log]")
      end

      it "handles single word categories" do
        mail = described_class.with(
          notification_category: "awards",
          source:,
          message_text:,
          notifications_email:
        ).notification

        expect(mail.subject).to include("[Awards]")
      end
    end

    context "when notifications_email is not present" do
      let(:mail) do
        described_class.with(
          notification_category:,
          source:,
          message_text:,
          notifications_email: nil
        ).notification
      end
    end
  end
end
