# frozen_string_literal: true

class NotificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 9, queue: :default

  ##
  # Sends email and Slack notifications for system events
  #
  # All messages from development or staging will appear with 'test' category in emails
  # and can be conditionally sent to Slack based on feature flag
  #
  # Examples
  #
  # NotificationWorker.perform_async("payments", "Canada Sales Reporting", "Canada 2024-11 sales report is ready - https://...", "green")
  # NotificationWorker.perform_async("payments", "VAT Reporting", "Report ready", "gray", { "attachments" => [{ title: "Link", text: "URL" }] })
  def perform(notification_category, source, message_text, color = "gray", options = {})
    attachments = Array(options["attachments"] || options[:attachments])
    notifications_email = GlobalConfig.get("NOTIFICATIONS_EMAIL_ADDRESS")

    if notifications_email.present?
      NotificationMailer.with(
        notification_category:,
        source:,
        message_text:,
        attachments:,
        notifications_email:
      ).notification.deliver_now
    end

    # Send to Slack unless feature flag is active
    return if Feature.active?(:skip_slack_notifications)

    SlackMessageWorker.perform_async(notification_category, source, message_text, color, options)
  end
end
