# frozen_string_literal: true

class NotificationService
  SLACK_MESSAGE_SEND_TIMEOUT = 5.seconds

  class << self
    def send_notification(room_name, sender, message_text, color = "gray", options = {})
      # Normalize room for environment
      room_name = "test" unless Rails.env.production?
      chat_room = CHAT_ROOMS[room_name.to_sym][:slack]
      return if chat_room.nil?

      # Always send email notification
      send_email(room_name, sender, message_text, options)

      # Conditionally send Slack notification
      send_slack(room_name, sender, message_text, color, options, chat_room) unless skip_slack?
    end

    private

    def send_email(room_name, sender, message_text, options)
      NotificationMailer.slack_notification(room_name, sender, message_text, options).deliver_later
    rescue StandardError => e
      Rails.logger.error("Failed to send notification email: #{e.message}")
    end

    def send_slack(room_name, sender, message_text, color, options, chat_room)
      hex_color = Color::CSS[color].html

      Timeout.timeout(SLACK_MESSAGE_SEND_TIMEOUT) do
        client = Slack::Notifier.new slack_webhook_url do
          defaults channel: "##{chat_room[:channel]}",
                   username: sender
        end

        opts = options.respond_to?(:with_indifferent_access) ? options.with_indifferent_access : options
        extra_attachments = opts[:attachments] || []
        
        client.ping("", attachments: [{
          fallback: message_text,
          color: hex_color,
          text: message_text
        }] + extra_attachments)
      end
    rescue StandardError, Timeout::Error => e
      raise SlackError, e.message unless e.message.include?("rate_limited")
    end

    def slack_webhook_url
      GlobalConfig.get("SLACK_WEBHOOK_URL")
    end

    def skip_slack?
      Feature.active?(:skip_slack_notifications)
    end
  end
end
