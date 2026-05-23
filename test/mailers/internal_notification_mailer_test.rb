# frozen_string_literal: true

require "test_helper"

class InternalNotificationMailerTest < ActionMailer::TestCase
  self.described_class = InternalNotificationMailer
  tests InternalNotificationMailer



  context_ InternalNotificationMailer do
  context_ "#notify" do
      subject(:mail) do
        described_class.notify(
          room_name: "payments",
          sender: "VAT Reporting",
          message_text: "VAT report generated successfully."
        )
      end

  test "sends to the configured email for the room" do
        expect(mail.to).to eq([INTERNAL_NOTIFICATION_EMAIL])
      end

  test "sets the subject with room name and sender" do
        expect(mail.subject).to eq("[test] [payments] VAT Reporting")
      end

  test "includes the sender and message in the body" do
        expect(mail.body.encoded).to include("VAT Reporting")
        expect(mail.body.encoded).to include("VAT report generated successfully.")
      end

  context_ "with attachments" do
        subject(:mail) do
          described_class.notify(
            room_name: "announcements",
            sender: "Report Bot",
            message_text: "Monthly report",
            attachments_data: [{ "fallback" => "Summary data", "text" => "Details here" }]
          )
        end

  test "includes attachment content in the body" do
          expect(mail.body.encoded).to include("Summary data")
          expect(mail.body.encoded).to include("Details here")
        end
      end

  context_ "when room has no email configured" do
        subject(:mail) do
          described_class.notify(
            room_name: "nonexistent_room",
            sender: "Test",
            message_text: "Should not send"
          )
        end

  test "returns a null mail" do
          expect(mail.to).to be_nil
        end
      end
    end
  end
end
