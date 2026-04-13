# frozen_string_literal: true

class InternalNotificationMailer < ApplicationMailer
  SUBJECT_PREFIX = ("[#{Rails.env}] " unless Rails.env.production?)

  default from: NOREPLY_EMAIL

  def notify(room_name:, sender:, message_text:, attachments_data: [])
    @sender = sender
    @message_text = message_text
    @room_name = room_name
    @attachments_data = attachments_data

    recipient = CHAT_ROOMS.dig(room_name.to_sym, :email)
    return if recipient.blank?

    mail(
      to: recipient,
      subject: "#{SUBJECT_PREFIX}[#{room_name}] #{sender}"
    )
  end
end
