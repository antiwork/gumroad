# frozen_string_literal: true

class SlackMessageWorker
  include Sidekiq::Job
  sidekiq_options retry: 9, queue: :default

  SLACK_MESSAGE_SEND_TIMEOUT = 5.seconds
  SLACK_WEBHOOK_URL = GlobalConfig.get("SLACK_WEBHOOK_URL")

  ##
  # Creates a Slack message in a given channel
  #
  # All messages from development or staging will appear in the 'test' channel
  #
  # Throws an error in order for Sidekiq to retry. Throws a SlackError so we
  # can ignore it for bug reporting
  #
  # Examples
  #
  # SlackMessageWorker.perform_async("announcements", "Example Service", "This is an example message")
  #
  # Options supports the key 'attachments':
  # Provide an array of hashes for attachments. See for more information about how
  # to format the hash for an attachment: https://api.slack.com/docs/attachments
  def perform(room_name, sender, message_text, color = "gray", options = {})
    room_name = "test" unless Rails.env.production?
    chat_room = CHAT_ROOMS[room_name.to_sym][:slack]
    return if chat_room.nil?

    hex_color = Color::CSS[color].html

    Timeout.timeout(SLACK_MESSAGE_SEND_TIMEOUT) do
      client = Slack::Notifier.new SLACK_WEBHOOK_URL do
        defaults channel: "##{chat_room[:channel]}",
                 username: sender
      end

      extra_attachments = (options["attachments"].nil? ? [] : options["attachments"])
      client.ping("", attachments: [{
        fallback: message_text,
        color: hex_color,
        text: message_text
      }] + extra_attachments)
    end
  rescue StandardError, Timeout::Error => e
    unless e.message.include? "rate_limited"
      raise SlackError, e.message
    end
  end
end

class SlackError < StandardError
end
