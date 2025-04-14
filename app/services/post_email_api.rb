# frozen_string_literal: true

class PostEmailApi
  RESEND_EXCLUDED_DOMAINS = ["example.com", "example.org", "example.net", "test.com"]
  private_constant :RESEND_EXCLUDED_DOMAINS

  def self.process(**args)
    post = args[:post]
    recipients = args[:recipients]

    if Feature.inactive?(:use_resend_for_post_emails, post&.seller)
      return PostSendgridApi.process(**args)
    end

    if Feature.active?(:force_resend_for_post_emails, post&.seller)
      return PostResendApi.process(**args)
    end

    # Split recipients based on email provider determination
    recipients_by_provider = recipients.group_by do |recipient|
      email = recipient[:email]

      # If the email contains non-ASCII characters or special characters, route it through SendGrid
      if valid_email_address_for_resend?(email)
        MailerInfo::Router.determine_email_provider(MailerInfo::DeliveryMethod::DOMAIN_CREATORS)
      else
        MailerInfo::EMAIL_PROVIDER_SENDGRID
      end
    end

    resend_recipients = recipients_by_provider[MailerInfo::EMAIL_PROVIDER_RESEND] || []
    sendgrid_recipients = recipients_by_provider[MailerInfo::EMAIL_PROVIDER_SENDGRID] || []

    PostResendApi.process(**args.merge(recipients: resend_recipients)) if resend_recipients.any?
    PostSendgridApi.process(**args.merge(recipients: sendgrid_recipients)) if sendgrid_recipients.any?
  end

  def self.max_recipients
    if Feature.active?(:use_resend_for_post_emails)
      PostResendApi::MAX_RECIPIENTS
    else
      PostSendgridApi::MAX_RECIPIENTS
    end
  end

  private
    def self.valid_email_address_for_resend?(email)
      return false unless email.present?
      return false unless email.ascii_only?
      return false if email.length > 254

      local_part, domain = email.split("@")
      return false unless local_part.present? && domain.present?
      return false if local_part.length > 64
      return false if local_part.match?(/[^a-zA-Z0-9.+_]/)
      return false unless domain.include?(".")
      return false if RESEND_EXCLUDED_DOMAINS.include?(domain)

      # Use Rails' built-in email validation regex
      email_regex = URI::MailTo::EMAIL_REGEXP
      email.match?(email_regex)
    end
end
