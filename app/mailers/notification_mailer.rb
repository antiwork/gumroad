# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  SUBJECT_PREFIX = ("[#{Rails.env}] " unless Rails.env.production?)
  NOTIFICATIONS_EMAIL = GlobalConfig.get("NOTIFICATIONS_EMAIL_ADDRESS")

  default from: ApplicationMailer::NOREPLY_EMAIL
  default to: NOTIFICATIONS_EMAIL

  layout false

  def slack_notification(room_name, sender, message_text, options = {})
    opts = options.with_indifferent_access
    @sender = sender
    @message_text = message_text
    @room_name = room_name
    @attachments = opts[:attachments] || []

    first_line = message_text.to_s.split("\n", 2).first.to_s.strip
    first_line = strip_slack_formatting(first_line)
    subject = "#{SUBJECT_PREFIX}[Gumroad Notifications][#{room_name.to_s.capitalize}] #{first_line}"

    mail subject:
  end

  private

  def strip_slack_formatting(text)
    text.gsub(/<([^|>]+)\|([^>]+)>/, '\2')
        .gsub(/<([^>]+)>/, '\1')
        .gsub(/:[a-z_]+:/, '')
        .strip
  end
end
