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
  # NotificationWorker.perform_async("payments", "Canada Sales Reporting", "Canada 2024-11 sales report is ready - https://...", { "color" => "green" })
  # NotificationWorker.perform_async("payments", "VAT Reporting", "Report ready", { "color" => "gray", attachments: [{ title: "Link", text: "URL" }] })
  def perform(notification_category, source, message_text, options = {})
    # Normalize to string keys
    options = options.transform_keys(&:to_s)

    color = options["color"] || "gray"
    attachments = Array(options["attachments"])
    notifications_email = GlobalConfig.get("NOTIFICATIONS_EMAIL_ADDRESS", "notifications@gumroad.com")

    # Send email if configured AND feature is active
    if notifications_email.present? && Feature.active?(:send_notifications_via_email)
      NotificationMailer.with(
        notification_category:,
        source:,
        message_text:,
        attachments:,
        notifications_email:
      ).notification.deliver_now
    end

    # Send to Slack if feature flag is active
    if Feature.active?(:send_notifications_via_slack)
      slack_options = options.merge("attachments" => attachments)
      SlackMessageWorker.perform_async(notification_category, source, message_text, color, slack_options)
    end
  end
end
