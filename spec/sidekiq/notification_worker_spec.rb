# frozen_string_literal: true

require "spec_helper"

describe NotificationWorker do
  describe "#perform" do
    let(:notification_category) { "payments" }
    let(:source) { "Canada Sales Reporting" }
    let(:message_text) { "Canada 2024-11 sales report is ready - https://example.com/report.csv" }
    let(:attachments) { [] }

    before do
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return("alerts@gumroad.com")
    end

    context "when notifications email is configured" do
      it "sends notification email" do
        expect do
          described_class.new.perform(notification_category, source, message_text, attachments)
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        email = ActionMailer::Base.deliveries.last
        expect(email.to).to eq(["alerts@gumroad.com"])
        expect(email.subject).to eq("[Gumroad Notifications][Payments] Canada 2024-11 sales report is ready - https://example.com/report.csv")
      end

      it "includes attachments in the email" do
        attachments_array = [
          {
            title: "Report Details",
            text: "Monthly sales breakdown",
            url: "https://example.com/details"
          }
        ]

        described_class.new.perform(notification_category, source, message_text, attachments_array)

        email = ActionMailer::Base.deliveries.last
        expect(email.body.encoded).to include("Report Details")
        expect(email.body.encoded).to include("Monthly sales breakdown")
        expect(email.body.encoded).to include("https://example.com/details")
      end

      it "handles string keys in attachments" do
        attachments_with_string_keys = [
          {
            "title" => "String Key Attachment",
            "text" => "Test text"
          }
        ]

        expect do
          described_class.new.perform(notification_category, source, message_text, attachments_with_string_keys)
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        email = ActionMailer::Base.deliveries.last
        expect(email.body.encoded).to include("String Key Attachment")
      end

      it "handles array message_text" do
        array_message = ["Line 1", "Line 2", "Line 3"]

        described_class.new.perform(notification_category, source, array_message, attachments)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to eq("[Gumroad Notifications][Payments] Line 1 Line 2 Line 3")
        expect(email.body.encoded).to include("Line 1")
        expect(email.body.encoded).to include("Line 2")
        expect(email.body.encoded).to include("Line 3")
      end

      it "uses default subject when message_text is empty" do
        described_class.new.perform(notification_category, source, "", attachments)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to eq("[Gumroad Notifications][Payments] System notification")
      end

      it "titleizes notification category in subject" do
        described_class.new.perform("internals_log", source, message_text, attachments)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Internals Log]")
      end
    end

    context "when notifications email is not configured" do
      before do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return(nil)
      end

      it "does not send notification email" do
        expect do
          described_class.new.perform(notification_category, source, message_text, attachments)
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end

    context "when notifications email is blank string" do
      before do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return("")
      end

      it "does not send notification email" do
        expect do
          described_class.new.perform(notification_category, source, message_text, attachments)
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end

    context "with various notification categories" do
      it "handles accounting category" do
        described_class.new.perform("accounting", "Fee Reporting", "Fee report ready", [])

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Accounting]")
      end

      it "handles awards category" do
        described_class.new.perform("awards", "Gumroad Awards", "Million dollar milestone!", [])

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Awards]")
      end

      it "handles migrations category" do
        described_class.new.perform("migrations", "Web", "Migration starting", [])

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Migrations]")
      end
    end
  end
end
