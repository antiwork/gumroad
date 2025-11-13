# frozen_string_literal: true

class SlackNotificationMailer < ApplicationMailer
  def notification
    @room_name = params[:room_name].to_s
    @slack_channel = params[:slack_channel]
    @sender = params[:sender]
    @message_text = params[:message_text]
    @attachments = Array(params[:attachments])
    notifications_email = params[:notifications_email]

    return unless notifications_email.present?

    mail(
      to: notifications_email,
      from: ApplicationMailer::NOREPLY_EMAIL,
      subject: formatted_subject
    )
  end

  private
    def formatted_subject
      readable_room = @room_name.titleize
      base_subject = Array(@message_text).flatten.compact.join(" ").squish
      suffix = base_subject.presence || "Slack notification"
      "[Gumroad Notifications][#{readable_room}] #{suffix}"
    end
end
