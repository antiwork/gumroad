# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  def slack_notification(room_name, sender, message_text, options = {})
    @sender = sender
    @message_text = message_text
    @room_name = room_name
    @attachments = options["attachments"] || []

    recipient = GlobalConfig.get("NOTIFICATIONS_EMAIL_ADDRESS")
    first_line = message_text.split("\n").first.strip
    subject = "[Gumroad Notifications][#{room_name.to_s.capitalize}] #{first_line}"

    mail(
      to: recipient,
      from: ApplicationMailer::NOREPLY_EMAIL,
      subject: subject
    )
  end
end
