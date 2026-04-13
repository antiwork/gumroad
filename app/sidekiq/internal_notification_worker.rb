# frozen_string_literal: true

class InternalNotificationWorker
  include Sidekiq::Job
  sidekiq_options retry: 9, queue: :default

  def perform(room_name, sender, message_text, _color = "gray", options = {})
    InternalNotificationMailer.notify(
      room_name: room_name,
      sender: sender,
      message_text: message_text,
      attachments_data: options.fetch("attachments", [])
    ).deliver_now
  end
end
