# frozen_string_literal: true

# This module is responsible for sending Devise email notifications via ActiveJob.
# See https://github.com/heartcombo/devise/blob/098345aace53d4ddf88e04f1eb2680e2676e8c28/lib/devise/models/authenticatable.rb#L133-L194.

module User::AsyncDeviseNotification
  extend ActiveSupport::Concern

  included do
    after_commit :send_pending_devise_notifications
  end

  protected
    def send_devise_notification(notification, *args)
      # If the record is new or changed then delay the
      # delivery until the after_commit callback otherwise
      # send now because after_commit will not be called.
      if new_record? || changed?
        pending_devise_notifications << [notification, args]
      else
        render_and_send_devise_message(notification, *args)
      end
    end

  private
    def send_pending_devise_notifications
      pending_devise_notifications.each do |notification, args|
        render_and_send_devise_message(notification, *args)
      end

      # Empty the pending notifications array because the
      # after_commit hook can be called multiple times which
      # could cause multiple emails to be sent.
      pending_devise_notifications.clear
    end

    def pending_devise_notifications
      @pending_devise_notifications ||= []
    end

    def render_and_send_devise_message(notification, *args)
      use_resend = should_use_resend_for_notification?(notification)
      track_notification_sent(notification) if trackable_notification?(notification)

      message = devise_mailer.send(notification, self, *args)

      if use_resend
        message.delivery_method_options = MailerInfo::DeliveryMethod.options(
          domain: :gumroad,
          email_provider: MailerInfo::EMAIL_PROVIDER_RESEND
        )
      end

      message.deliver_later(queue: "critical", wait: 3.seconds)
    end

    def should_use_resend_for_notification?(notification)
      return false unless trackable_notification?(notification)

      ResendFallbackTracker.should_use_resend_fallback?(
        email_type: notification_to_email_type(notification),
        user_id: id
      )
    end

    def track_notification_sent(notification)
      ResendFallbackTracker.record_email_sent(
        email_type: notification_to_email_type(notification),
        user_id: id
      )
    end

    def trackable_notification?(notification)
      notification == :reset_password_instructions
    end

    def notification_to_email_type(notification)
      case notification
      when :reset_password_instructions then :password_reset
      else notification
      end
    end
end
