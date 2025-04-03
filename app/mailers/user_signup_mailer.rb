# frozen_string_literal: true

class UserSignupMailer < Devise::Mailer
  include RescueSmtpErrors
  helper MailerHelper
  layout "layouts/email"

  def email_changed(record, opts = {})
    opts[:from] = ApplicationMailer::NOREPLY_EMAIL_WITH_NAME
    opts[:reply_to] = ApplicationMailer::NOREPLY_EMAIL_WITH_NAME
    super
  end
end
