# frozen_string_literal: true

class InternalNotificationMailerPreview < ActionMailer::Preview
  def payment_notification
    InternalNotificationMailer.notify(
      "payments",
      "Canada Sales Fees Reporting",
      "Canada 2026-03 sales fees report is ready - https://s3.amazonaws.com/example/report.csv",
    )
  end

  def risk_notification
    InternalNotificationMailer.notify(
      "risk",
      "Iffy Risk Review",
      "New high-risk seller flagged: user #12345 (example@gmail.com). 3 chargebacks in 7 days, $2,400 total volume. Review at https://iffy.gumroad.com",
    )
  end

  def migration_notification
    InternalNotificationMailer.notify(
      "migrations",
      "Web",
      "*[production] Will execute migration:* AddIndexToUsersEmail",
    )
  end

  def award_notification
    InternalNotificationMailer.notify(
      "awards",
      "Gumroad Awards",
      "🎉 Congratulations! Creator 'Digital Art Studio' just crossed $1,000,000 in lifetime sales!",
    )
  end

  def notification_with_attachment
    InternalNotificationMailer.notify(
      "announcements",
      "VAT Rate Updater",
      "VAT rate has changed for DE from 19.0 to 20.0",
      "gray",
      "attachments" => [{ "fallback" => "Details: Germany VAT rate updated effective 2026-04-01", "text" => "Old rate: 19.0%\nNew rate: 20.0%\nEffective: 2026-04-01" }]
    )
  end
end
