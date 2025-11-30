# frozen_string_literal: true

class NotificationMailerPreview < ActionMailer::Preview
  def notification
    NotificationMailer.with(
      notification_category: "payments",
      source: "VAT Reporting Bot",
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
