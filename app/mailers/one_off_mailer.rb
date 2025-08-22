# frozen_string_literal: true

class OneOffMailer < ApplicationMailer
  helper InstallmentsHelper

  layout "layouts/email"

  # Mailer used to send one-off emails to user, usually via Rails console
  # `from` email address is not being monitored. If you need to receive replies from users, pass the optional
  # param `reply_to`, e.g. reply_to: ApplicationMailer::NOREPLY_EMAIL_WITH_NAME
  def email(user_id: nil, email: nil, subject:, body:, reply_to: nil)
    email ||= User.alive.not_suspended.find_by(id: user_id)&.form_email
    return unless EmailFormatValidator.valid?(email)

    @subject = subject
    @body = body

    options = {
      to: email,
      from: "Gumroad <hi@#{CUSTOMERS_MAIL_DOMAIN}>",
      subject: @subject,
      delivery_method_options: MailerInfo.random_delivery_method_options(domain: :customers)
    }
    options[:reply_to] = reply_to if reply_to.present?

    mail options
  end

  def email_using_installment(user_id: nil, email: nil, installment_external_id:, subject: nil, reply_to: nil)
    @installment = Installment.find_by_external_id(installment_external_id)

    email(user_id:, email:, subject: subject || @installment.subject, reply_to:, body: nil)
  end
end
