# frozen_string_literal: true

require_relative "../../app/models/mailer_info"
require_relative "../../app/models/mailer_info/delivery_method"

if Rails.env.production?
  FOLLOWER_CONFIRMATION_MAIL_DOMAIN = GlobalConfig.get("FOLLOWER_CONFIRMATION_MAIL_DOMAIN_PROD", "followers.gumroad.com")
  CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN = GlobalConfig.get("CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN_PROD", "creators.gumroad.com")
  CUSTOMERS_MAIL_DOMAIN = GlobalConfig.get("CUSTOMERS_MAIL_DOMAIN_PROD", "customers.gumroad.com")
else
  FOLLOWER_CONFIRMATION_MAIL_DOMAIN = GlobalConfig.get("FOLLOWER_CONFIRMATION_MAIL_DOMAIN_DEV", "staging.followers.gumroad.com")
  CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN = GlobalConfig.get("CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN_DEV", "staging.creators.gumroad.com")
  CUSTOMERS_MAIL_DOMAIN = GlobalConfig.get("CUSTOMERS_MAIL_DOMAIN_DEV", "staging.customers.gumroad.com")
end

SENDGRID_SMTP_ADDRESS = GlobalConfig.get("SENDGRID_SMTP_ADDRESS", "smtp.sendgrid.net")
RESEND_SMTP_ADDRESS = GlobalConfig.get("RESEND_SMTP_ADDRESS", "smtp.resend.com")
EMAIL_CREDENTIALS = {
  MailerInfo::EMAIL_PROVIDER_SENDGRID => {
    gumroad: { # For emails that are sent as Gumroad (e.g. password reset)
      address: SENDGRID_SMTP_ADDRESS,
      username: "apikey",
      password: GlobalConfig.get("SENDGRID_GUMROAD_TRANSACTIONS_API_KEY"),
      domain: DEFAULT_EMAIL_DOMAIN,
    },
    followers: { # For follower confirmation emails
      address: SENDGRID_SMTP_ADDRESS,
      username: "apikey",
      password: GlobalConfig.get("SENDGRID_GUMROAD_FOLLOWER_CONFIRMATION_API_KEY"),
      domain: FOLLOWER_CONFIRMATION_MAIL_DOMAIN,
    },
    creators: { # For emails that are sent on behalf of creators (e.g. product updates, subscription installments)
      address: SENDGRID_SMTP_ADDRESS,
      username: "apikey",
      password: GlobalConfig.get("SENDGRID_GR_CREATORS_API_KEY"),
      domain: CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN,
    },
    customers: { # For customer / customer_low_priority emails
      address: SENDGRID_SMTP_ADDRESS,
      username: "apikey",
      password: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_API_KEY"),
      domain: CUSTOMERS_MAIL_DOMAIN,
      levels: {
        level_1: {
          username: "apikey",
          password: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_API_KEY"),
          domain: CUSTOMERS_MAIL_DOMAIN,
        },
        level_2: {
          username: "apikey",
          password: GlobalConfig.get("SENDGRID_GR_CUSTOMERS_LEVEL_2_API_KEY"),
          domain: CUSTOMERS_MAIL_DOMAIN,
        }
      }
    },
  },
  MailerInfo::EMAIL_PROVIDER_RESEND => {
    gumroad: { # For emails that are sent as Gumroad (e.g. password reset)
      address: RESEND_SMTP_ADDRESS,
      username: "resend",
      password: GlobalConfig.get("RESEND_DEFAULT_API_KEY"),
      domain: DEFAULT_EMAIL_DOMAIN
    },
    followers: { # For follower confirmation emails
      address: RESEND_SMTP_ADDRESS,
      username: "resend",
      password: GlobalConfig.get("RESEND_FOLLOWERS_API_KEY"),
      domain: FOLLOWER_CONFIRMATION_MAIL_DOMAIN,
    },
    creators: { # For emails that are sent on behalf of creators (e.g. product updates, subscription installments)
      address: RESEND_SMTP_ADDRESS,
      username: "resend",
      password: GlobalConfig.get("RESEND_CREATORS_API_KEY"),
      domain: CREATOR_CONTACTING_CUSTOMERS_MAIL_DOMAIN,
    },
    customers: { # For customer / customer_low_priority emails
      address: RESEND_SMTP_ADDRESS,
      username: "resend",
      password: GlobalConfig.get("RESEND_CUSTOMERS_API_KEY"),
      domain: CUSTOMERS_MAIL_DOMAIN,
      levels: {
        level_1: {
          username: "resend",
          password: GlobalConfig.get("RESEND_CUSTOMERS_API_KEY"),
          domain: CUSTOMERS_MAIL_DOMAIN,
        },
        level_2: {
          username: "resend",
          password: GlobalConfig.get("RESEND_CUSTOMERS_LEVEL_2_API_KEY"),
          domain: CUSTOMERS_MAIL_DOMAIN,
        }
      }
    },
  }
}.freeze

default_smtp_settings = MailerInfo.default_delivery_method_options(domain: :gumroad).merge(
  port: 587,
  authentication: :plain,
  enable_starttls_auto: true
)

case Rails.env
when "production", "staging"
  Rails.application.config.action_mailer.delivery_method = :smtp
  Rails.application.config.action_mailer.smtp_settings = default_smtp_settings
when "test"
  Rails.application.config.action_mailer.delivery_method = :test
when "development"
  Rails.application.config.action_mailer.delivery_method = :smtp
  Rails.application.config.action_mailer.smtp_settings = default_smtp_settings
  Rails.application.config.action_mailer.perform_deliveries = (ENV["ACTION_MAILER_SKIP_DELIVERIES"] != "1")
end

Rails.application.config.action_mailer.default_url_options = {
  host: DOMAIN,
  protocol: PROTOCOL
}
Rails.application.config.action_mailer.deliver_later_queue_name = :default

SendGridApiResponseError = Class.new(StandardError)
ResendApiResponseError = Class.new(StandardError)
