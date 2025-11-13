# frozen_string_literal: true

class SlackNotificationMailerPreview < ActionMailer::Preview
  def notification
    SlackNotificationMailer.with(
      room_name: "payments",
      slack_channel: "accounting-alerts",
      sender: "VAT Reporting Bot",
      message_text: ["Quarterly report is ready"],
      attachments: [
        {
          title: "Report URL",
          text: "https://example.com/reports/q4"
        }
      ],
      notifications_email: "alerts@gumroad.com"
    ).notification
  end
end

