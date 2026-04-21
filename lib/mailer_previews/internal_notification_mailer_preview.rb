# frozen_string_literal: true

class InternalNotificationMailerPreview < ActionMailer::Preview
  def payment_notification
    InternalNotificationMailer.notify(
      room_name: "payments",
      sender: "Canada Sales Fees Reporting",
      message_text: "Canada 2026-03 sales fees report is ready - https://s3.amazonaws.com/example/report.csv",
    )
  end

  def risk_notification
    InternalNotificationMailer.notify(
      room_name: "risk",
      sender: "Content Moderation",
      message_text: "Content moderation blocked publish: Product ##{12345} (Example) - OpenAI moderation flagged: sexual (score: 0.95, threshold: 0.8)",
    )
  end

  def migration_notification
    InternalNotificationMailer.notify(
      room_name: "migrations",
      sender: "Web",
      message_text: "*[production] Will execute migration:* AddIndexToUsersEmail",
    )
  end

  def award_notification
    InternalNotificationMailer.notify(
      room_name: "awards",
      sender: "Gumroad Awards",
      message_text: "Congratulations! Creator 'Digital Art Studio' just crossed $1,000,000 in lifetime sales!",
    )
  end

  def notification_with_attachment
    InternalNotificationMailer.notify(
      room_name: "announcements",
      sender: "VAT Rate Updater",
      message_text: "VAT rate has changed for DE from 19.0 to 20.0",
      attachments_data: [{ "fallback" => "Details: Germany VAT rate updated effective 2026-04-01", "text" => "Old rate: 19.0%\nNew rate: 20.0%\nEffective: 2026-04-01" }]
    )
  end
end
