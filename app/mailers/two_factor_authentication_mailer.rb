# frozen_string_literal: true

class TwoFactorAuthenticationMailer < ApplicationMailer
  after_action :deliver_email
  after_action :record_email_sent

  layout "layouts/email"

  # TODO(ershad): Remove this once the issue with Resend is resolved
  default delivery_method_options: -> { MailerInfo.default_delivery_method_options(domain: :gumroad) }

  def authentication_token(user_id, email_provider: nil)
    @user = User.find(user_id)
    @authentication_token = @user.otp_code
    @subject = "Your authentication token is #{@authentication_token}"
    @email_provider = email_provider
  end

  private
    def deliver_email
      email = @user.email
      return unless EmailFormatValidator.valid?(email)

      mailer_args = { to: email, subject: @subject }
      mailer_args[:from] = @from if @from.present?

      if @email_provider.present?
        mailer_args[:delivery_method_options] = MailerInfo::DeliveryMethod.options(
          domain: :gumroad,
          email_provider: @email_provider
        )
      end

      mail(mailer_args)
    end

    def record_email_sent
      EmailRouterFallbackService.record_email_sent(user: @user)
    end
end
