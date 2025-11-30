# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  def notification
    @notification_category = params[:notification_category].to_s
    @source = params[:source]
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
      readable_category = @notification_category.titleize
      base_subject = Array(@message_text).flatten.compact.join(" ").squish
      suffix = base_subject.presence || "System notification"
      "[Gumroad Notifications][#{readable_category}] #{suffix}"
    end
end
