# frozen_string_literal: true

module MailerInfo::DeliveryMethod
  extend self

  include Kernel

  DOMAIN_GUMROAD = :gumroad
  DOMAIN_FOLLOWERS = :followers
  DOMAIN_CREATORS = :creators
  DOMAIN_CUSTOMERS = :customers

  DOMAINS = [DOMAIN_GUMROAD, DOMAIN_FOLLOWERS, DOMAIN_CREATORS, DOMAIN_CUSTOMERS]

  # True when these SMTP settings will send through Resend rather than SendGrid.
  def resend?(settings)
    settings.present? && settings[:address] == RESEND_SMTP_ADDRESS
  end

  # Given the SMTP settings a message is already configured with, return the
  # equivalent settings for the same sending domain and the same seller mailer
  # level on SendGrid. Returns nil when the settings don't correspond to any
  # Resend credential set we know, so callers leave the message alone rather
  # than guess at credentials.
  #
  # This exists so a message that has already been built can be redirected to
  # SendGrid without the redirecting code needing to know which mail domain or
  # mailer level the mailer method picked — see ApplicationMailer#process and
  # MailerInfo::UNITED_INTERNET_RECIPIENT_DOMAINS.
  def sendgrid_equivalent_options(settings)
    return nil unless resend?(settings)

    resend_credentials = EMAIL_CREDENTIALS[MailerInfo::EMAIL_PROVIDER_RESEND]
    domain_key = resend_credentials.keys.find do |key|
      resend_credentials[key][:domain] == settings[:domain]
    end
    return nil if domain_key.nil?

    # A domain's `levels` entries differ from each other only by credential, and
    # level_1 is identical to the domain's top-level credential. So the only
    # distinction that has to survive the swap is "was this a level_2 seller".
    level_2_password = resend_credentials.dig(domain_key, :levels, :level_2, :password)
    sendgrid = EMAIL_CREDENTIALS[MailerInfo::EMAIL_PROVIDER_SENDGRID][domain_key]
    credentials = if level_2_password.present? && settings[:password] == level_2_password
      sendgrid[:levels][:level_2]
    else
      sendgrid
    end

    {
      address: sendgrid[:address],
      domain: credentials[:domain],
      user_name: credentials[:username],
      password: credentials[:password],
    }
  end

  def options(domain:, email_provider:, seller: nil)
    raise ArgumentError, "Invalid domain: #{domain}" unless DOMAINS.include?(domain)
    raise ArgumentError, "Seller is only allowed for customers domain" if seller && domain != DOMAIN_CUSTOMERS

    if seller.present?
      {
        address: EMAIL_CREDENTIALS[email_provider][domain][:address],
        domain: EMAIL_CREDENTIALS[email_provider][domain][:levels][seller.mailer_level][:domain],
        user_name: EMAIL_CREDENTIALS[email_provider][domain][:levels][seller.mailer_level][:username],
        password: EMAIL_CREDENTIALS[email_provider][domain][:levels][seller.mailer_level][:password],
      }
    else
      {
        address: EMAIL_CREDENTIALS[email_provider][domain][:address],
        domain: EMAIL_CREDENTIALS[email_provider][domain][:domain],
        user_name: EMAIL_CREDENTIALS[email_provider][domain][:username],
        password: EMAIL_CREDENTIALS[email_provider][domain][:password],
      }
    end
  end
end
