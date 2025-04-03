# frozen_string_literal: true

module MailerInfo
  extend self
  include Kernel

  EMAIL_PROVIDER_SENDGRID = "sendgrid"
  EMAIL_PROVIDER_RESEND = "resend"

  SENDGRID_X_SMTPAPI_HEADER = "X-SMTPAPI"

  FIELD_NAMES = %i[
    email_provider environment category mailer_class mailer_method mailer_args purchase_id charge_id workflow_ids post_id follower_id affiliate_id
  ].freeze

  FIELD_EMAIL_PROVIDER = :email_provider
  FIELD_ENVIRONMENT = :environment
  FIELD_CATEGORY = :category
  FIELD_MAILER_CLASS = :mailer_class
  FIELD_MAILER_METHOD = :mailer_method
  FIELD_MAILER_ARGS = :mailer_args
  FIELD_PURCHASE_ID = :purchase_id
  FIELD_CHARGE_ID = :charge_id
  FIELD_WORKFLOW_IDS = :workflow_ids
  FIELD_POST_ID = :post_id
  FIELD_FOLLOWER_ID = :follower_id
  FIELD_AFFILIATE_ID = :affiliate_id

  def build_headers(mailer_class:, mailer_method:, mailer_args:, email_provider:)
    MailerInfo::HeaderBuilder.perform(mailer_class:, mailer_method:, mailer_args:, email_provider:)
  end
  GUMROAD_HEADER_PREFIX = "X-GUM-"

  def header_name(name)
    raise ArgumentError, "Invalid header field: #{name}" unless FIELD_NAMES.include?(name)
    GUMROAD_HEADER_PREFIX + name.to_s.split("_").map(&:capitalize).join("-")
  end

  def encrypt(value)
    MailerInfo::Encryption.encrypt(value)
  end

  def decrypt(encrypted_value)
    MailerInfo::Encryption.decrypt(encrypted_value)
  end

  # Sample Resend headers:
  # [
  #   {
  #     "name": "X-Gum-Environment",
  #     "value": "v1:T4Atudv1nP58+gprjqKMJA==:fGNbbVO69Zrw7kSnULg2mw=="
  #   },
  #   {
  #     "name": "X-Gum-Mailer-Class",
  #     "value": "v1:4/KqqxSld7KZg35TizeOzg==:roev9VWcJg5De5uJ95tWbQ=="
  #   }
  # ]
  def parse_resend_webhook_header(headers_json, header_name)
    header_field_name = header_name(header_name)
    header_value = headers_json
      &.find { _1["name"].downcase == header_field_name.downcase }
      &.dig("value")
    decrypt(header_value)
  end

  def random_email_provider(domain)
    MailerInfo::Router.determine_email_provider(domain)
  end

  def random_delivery_method_options(domain:, seller: nil)
    MailerInfo::DeliveryMethod.options(domain:, email_provider: random_email_provider(domain), seller:)
  end

  def default_delivery_method_options(domain:)
    MailerInfo::DeliveryMethod.options(domain:, email_provider: EMAIL_PROVIDER_SENDGRID)
  end
end
