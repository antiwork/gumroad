# frozen_string_literal: true

class NotificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 9, queue: :default

  ##
  # Sends email notifications for system events
  #
  # Examples
  #
  # NotificationWorker.perform_async("payments", "Canada Sales Reporting", "Canada 2024-11 sales report is ready - https://...")
  # NotificationWorker.perform_async("payments", "VAT Reporting", "Report ready", [{ title: "Link", text: "URL" }])
  def perform(notification_category, source, message_text, attachments = [])
    notifications_email = GlobalConfig.get("NOTIFICATIONS_EMAIL_ADDRESS")

    return unless notifications_email.present?

    NotificationMailer.with(
      notification_category:,
      source:,
      message_text:,
      attachments: Array(attachments),
      notifications_email:
    ).notification.deliver_now
  end
end
