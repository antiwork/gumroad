# frozen_string_literal: true

class NotificationMailerPreview < ActionMailer::Preview
  def slack_notification_simple
    NotificationMailer.slack_notification(
      "accounting",
      "Tax System",
      "Multi-state summary report for 2025-10 is ready\nView report: https://example.com/reports/12345"
    )
  end

  def slack_notification_with_attachments
    NotificationMailer.slack_notification(
      "payments",
      "PayPal Monitor",
      "PayPal balance needs to be $200,000.00",
      {
        "attachments" => [
          {
            "title" => "Current Balance",
            "text" => "$150,000.00"
          },
          {
            "title" => "Required Action",
            "text" => "Transfer $50,000.00 to PayPal account"
          }
        ]
      }
    )
  end

  def slack_notification_awards
    NotificationMailer.slack_notification(
      "awards",
      "Gumroad Awards",
      "<https://gumroad.com/seller|Jane Doe> has crossed $1M in earnings 🎉\n• Name: Jane Doe\n• Username: janedoe\n• Email: jane@example.com"
    )
  end
end
