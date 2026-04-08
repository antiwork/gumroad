# frozen_string_literal: true

class SlackMessageWorker
  include Sidekiq::Job
  sidekiq_options retry: 9, queue: :default

  ##
  # Sends an internal notification email for a given chat room
  #
  # Keeps the same interface as the old Slack-based implementation so
  # callers do not need to change.
  #
  # Examples
  #
  # SlackMessageWorker.perform_async("announcements", "Example Service", "This is an example message")
  #
  # Options supports the key 'attachments':
  # Provide an array of hashes for attachments.
  def perform(room_name, sender, message_text, _color = "gray", options = {})
    InternalNotificationMailer.notify(
      room_name: room_name,
      sender: sender,
      message_text: message_text,
      attachments_data: options.fetch("attachments", [])
    ).deliver_now
  end
end
