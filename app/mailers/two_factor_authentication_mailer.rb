# frozen_string_literal: true

class TwoFactorAuthenticationMailer < ApplicationMailer
  after_action :deliver_email

  layout "layouts/email"

  # TODO(ershad): Remove this once the issue with Resend is resolved
  default delivery_method_options: -> { MailerInfo.default_delivery_method_options(domain: :gumroad) }

  def authentication_token(user_id)
    @user = User.find(user_id)
    @authentication_token = @user.otp_code
    @subject = "Your authentication token is #{@authentication_token}"
  end

  private
    def deliver_email
      email = @user.email
      return unless EmailFormatValidator.valid?(email)

      mailer_args = { to: email, subject: @subject }
      mailer_args[:from] = @from if @from.present?
      mail(mailer_args)
    end
end
