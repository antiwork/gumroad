# frozen_string_literal: true

class ApplicationMailer < ActionMailer::Base
  include RescueSmtpErrors, MailerHelper
  helper MailerHelper

  # Constants for Gumroad emails
  {
    ADMIN_EMAIL: "hi@#{DEFAULT_EMAIL_DOMAIN}",
    DEVELOPERS_EMAIL: "developers@#{DEFAULT_EMAIL_DOMAIN}",
    NOREPLY_EMAIL: "noreply@#{DEFAULT_EMAIL_DOMAIN}",
    PAYMENTS_EMAIL: "payments@#{DEFAULT_EMAIL_DOMAIN}",
    RISK_EMAIL: "risk@#{DEFAULT_EMAIL_DOMAIN}",
    SUPPORT_EMAIL: "support@#{DEFAULT_EMAIL_DOMAIN}"
  }.each do |key, email|
    const_set(key, email)
    const_set("#{key}_WITH_NAME", email_address_with_name(email, "Gumroad"))
  end

  default from: NOREPLY_EMAIL_WITH_NAME,
          delivery_method_options: -> { MailerInfo.random_delivery_method_options(domain: :gumroad) }

  after_action :validate_from_email_domain!

  ruby2_keywords def process(name, *args)
    super
    set_custom_headers(name, args)
  end

  private
    def from_email_address_with_name(name = "", email = NOREPLY_EMAIL)
      name = from_email_address_name(name)
      email_address_with_name(email, name)
    end

    def set_custom_headers(mailer_action, mailer_args)
      return if self.message.class == ActionMailer::Base::NullMail

      # Ensure the correct email provider for building the headers is used
      email_provider = self.message.delivery_method.settings[:address] == RESEND_SMTP_ADDRESS ? MailerInfo::EMAIL_PROVIDER_RESEND : MailerInfo::EMAIL_PROVIDER_SENDGRID
      custom_headers = MailerInfo.build_headers(mailer_class: self.class.name, mailer_method: mailer_action.to_s, mailer_args:, email_provider:)
      custom_headers.each do |name, value|
        headers[name] = value
      end
    end

    # From email domain must match the domain associated with the API key on Resend
    def validate_from_email_domain!
      return if message.subject.nil?

      expected_domain = message.delivery_method.settings[:domain]
      message.from.each do |from|
        next if from.split("@").last == expected_domain

        raise "From email `#{from}` domain does not match expected delivery domain `#{expected_domain}`"
      end
    end
end
