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

    # CC Gumclaw on every internal notification, in addition to the room's own recipient,
    # so it ingests the full stream. Skip if it's already the room's recipient (no dup).
    always_cc = INTERNAL_NOTIFICATION_ALWAYS_CC.presence
    cc = (always_cc && always_cc != recipient) ? always_cc : nil

    mail(
      to: recipient,
      cc: cc,
      subject: "#{SUBJECT_PREFIX}[#{room_name}] #{sender}"
    )
  end
end
