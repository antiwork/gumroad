# frozen_string_literal: true

class NotificationMailer < ApplicationMailer
  layout "layouts/email"

  def notification
    @notification_category = params[:notification_category].to_s
    @source = params[:source]
    @message_lines = format_message_lines(params[:message_text])
    @attachments = format_attachments(Array(params[:attachments]))
    @subject = formatted_subject
    notifications_email = params[:notifications_email]

    return unless notifications_email.present?

    mail(
      to: notifications_email,
      from: ApplicationMailer::NOREPLY_EMAIL,
      subject: @subject
    )
  end

  private
    def formatted_subject
      readable_category = @notification_category.titleize
      base_subject = Array(@message_lines).flatten.compact.join(" ").squish
      suffix = base_subject.presence || "System notification"
      "[Gumroad Notifications][#{readable_category}] #{suffix}"
    end

    def format_message_lines(message_text)
      Array(message_text).flatten.compact.map(&:to_s).map(&:strip).reject(&:blank?)
    end

    def format_attachments(attachments)
      attachments.map do |attachment|
        {
          title: attachment[:title] || attachment["title"],
          text: attachment[:text] || attachment["text"],
          url: attachment[:url] || attachment["url"] || attachment[:title_link] || attachment["title_link"]
        }
      end
    end
end
