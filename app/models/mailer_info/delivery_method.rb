# frozen_string_literal: true

module MailerInfo::DeliveryMethod
  extend self

  include Kernel

  DOMAIN_GUMROAD = :gumroad
  DOMAIN_FOLLOWERS = :followers
  DOMAIN_CREATORS = :creators
  DOMAIN_CUSTOMERS = :customers

  DOMAINS = [DOMAIN_GUMROAD, DOMAIN_FOLLOWERS, DOMAIN_CREATORS, DOMAIN_CUSTOMERS]

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
