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

  # Recipient domains operated by United Internet's 1&1 Mail & Media, which runs
  # web.de, GMX and mail.com — together Germany's largest consumer mail estate,
  # and all three on one inbound platform (mail.com was migrated onto the GMX
  # platform after United Internet acquired it in 2010, and the three brands
  # share a postmaster/blocklist operation). United Internet policy-blocks the
  # Amazon SES IP range that Resend sends from: every send bounces with
  # "550 Reject due to policy restrictions" (their code r1102), so a buyer at
  # these domains who gets routed to Resend pays and never receives their
  # receipt or download link. The very same addresses accept our SendGrid mail
  # without issue, so we pin them to SendGrid instead of letting the random
  # provider split pick Resend.
  #
  # Matched exactly rather than by suffix: these are consumer mailboxes that
  # exist only at the apex, and suffix matching would also capture unrelated
  # third-party subdomains that happen to end in one of these names.
  #
  # mail.com additionally fronts a large family of vanity domains (email.com,
  # usa.com, …) on the same platform. Those are NOT listed here because the set
  # has not been verified against United Internet's own documentation; add them
  # if a bounce is actually observed rather than guessing at the list.
  # See https://github.com/antiwork/gumroad-private/issues/1462
  UNITED_INTERNET_RECIPIENT_DOMAINS = %w[
    web.de
    gmx.de gmx.net gmx.com gmx.at gmx.ch gmx.us gmx.fr gmx.es gmx.co.uk
    mail.com
  ].freeze

  # `to` accepts whatever a mailer passes as the `to:` header: a single email
  # string (possibly in "Name <email>" form) or an array of them.
  def force_sendgrid_for_recipients?(to)
    Array(to).compact.any? do |recipient|
      # strip BEFORE removing the bracket: " Name <user@web.de> " ends in a
      # space, so delete_suffix(">") would be a no-op and the domain would keep
      # its bracket and never match.
      domain = recipient.to_s.strip.split("@").last.to_s.delete_suffix(">").strip.downcase
      UNITED_INTERNET_RECIPIENT_DOMAINS.include?(domain)
    end
  end

  def random_email_provider(domain)
    MailerInfo::Router.determine_email_provider(domain)
  end

  # `to` is the recipient(s) of the email being built. When any recipient is
  # at a domain that rejects Resend's sending IPs (see
  # UNITED_INTERNET_RECIPIENT_DOMAINS above), we bypass the random
  # SendGrid/Resend split and force SendGrid so the email actually arrives.
  def random_delivery_method_options(domain:, seller: nil, to: nil)
    email_provider = force_sendgrid_for_recipients?(to) ? EMAIL_PROVIDER_SENDGRID : random_email_provider(domain)
    MailerInfo::DeliveryMethod.options(domain:, email_provider:, seller:)
  end

  def default_delivery_method_options(domain:)
    MailerInfo::DeliveryMethod.options(domain:, email_provider: EMAIL_PROVIDER_SENDGRID)
  end
end
