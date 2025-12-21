# frozen_string_literal: true

require "spec_helper"

describe NotificationWorker do
  describe "#perform" do
    let(:notification_category) { "payments" }
    let(:source) { "Canada Sales Reporting" }
    let(:message_text) { "Canada 2024-11 sales report is ready - https://example.com/report.csv" }

    before do
      allow(Feature).to receive(:active?).with(:send_notifications_via_email).and_return(true)
      allow(Feature).to receive(:active?).with(:send_notifications_via_slack).and_return(false)
      allow(GlobalConfig).to receive(:get).and_call_original
      allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS").and_return("notifications@gumroad.com")
    end

    context "when notifications email is configured" do
      it "sends notification email" do
        options = {}
        expect do
          described_class.new.perform(notification_category, source, message_text, options)
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        email = ActionMailer::Base.deliveries.last
        expect(email.to).to eq(["notifications@gumroad.com"])
        expect(email.subject).to eq("[Gumroad Notifications][Payments] Canada 2024-11 sales report is ready - https://example.com/report.csv")
      end


      it "handles string keys in attachments" do
        attachments_with_string_keys = [
          {
            "title" => "String Key Attachment",
            "text" => "Test text"
          }
        ]

        options = { "color" => "gray", "attachments" => attachments_with_string_keys }
        expect do
          described_class.new.perform(notification_category, source, message_text, options)
        end.to change { ActionMailer::Base.deliveries.count }.by(1)

        email = ActionMailer::Base.deliveries.last
        expect(email.body.encoded).to include("String Key Attachment")
      end

      it "handles array message_text" do
        array_message = ["Line 1", "Line 2", "Line 3"]
        options = {}
        described_class.new.perform(notification_category, source, array_message, options)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to eq("[Gumroad Notifications][Payments] Line 1 Line 2 Line 3")
        expect(email.body.encoded).to include("Line 1")
        expect(email.body.encoded).to include("Line 2")
        expect(email.body.encoded).to include("Line 3")
      end

      it "uses default subject when message_text is empty" do
        options = {}
        described_class.new.perform(notification_category, source, "", options)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to eq("[Gumroad Notifications][Payments] System notification")
      end

      it "titleizes notification category in subject" do
        options = {}
        described_class.new.perform("internals_log", source, message_text, options)

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Internals Log]")
      end
    end

    context "when notifications email is not configured" do
      before do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS", "notifications@gumroad.com").and_return(nil)
      end

      it "does not send notification email" do
        expect do
          described_class.new.perform(notification_category, source, message_text, {})
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end

    context "when notifications email is blank string" do
      before do
        allow(GlobalConfig).to receive(:get).and_call_original
        allow(GlobalConfig).to receive(:get).with("NOTIFICATIONS_EMAIL_ADDRESS", "notifications@gumroad.com").and_return("")
      end

      it "does not send notification email" do
        expect do
          described_class.new.perform(notification_category, source, message_text, {})
        end.not_to change { ActionMailer::Base.deliveries.count }
      end
    end

    context "with various notification categories" do
      it "handles accounting category" do
        described_class.new.perform("accounting", "Fee Reporting", "Fee report ready", {})

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Accounting]")
      end

      it "handles awards category" do
        described_class.new.perform("awards", "Gumroad Awards", "Million dollar milestone!", {})

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Awards]")
      end

      it "handles migrations category" do
        described_class.new.perform("migrations", "Web", "Migration starting", {})

        email = ActionMailer::Base.deliveries.last
        expect(email.subject).to include("[Migrations]")
      end
    end
  end
end
