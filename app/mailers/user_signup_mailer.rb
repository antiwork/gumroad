# frozen_string_literal: true

class UserSignupMailer < Devise::Mailer
  include RescueSmtpErrors
  helper MailerHelper
  helper ViteRails::TagHelpers
  helper ApplicationHelper
  layout "layouts/email"

  # Devise::Mailer inherits from ActionMailer::Base directly, so it misses
  # ApplicationMailer's header injection. Without these headers, SendGrid's
  # event webhook can't tell us which mailer a bounce/block belongs to —
  # and we need to recognize failed signup-confirmation sends to auto-retry
  # transient failures (see HandleEmailEventInfo::ForSignupConfirmationEmail).
  ruby2_keywords def process(name, *args)
    super
    set_custom_headers(name, args)
  end

  def email_changed(record, opts = {})
    opts[:from] = ApplicationMailer::NOREPLY_EMAIL_WITH_NAME
    opts[:reply_to] = ApplicationMailer::NOREPLY_EMAIL_WITH_NAME
    # Devise sends this notification with `to:` set to the address the account
    # had before the change (see Devise's send_email_changed_notification).
    # Don't read the old/new addresses off the record at render time: when the
    # change is applied and auto-confirmed in one step (e.g. the Google OAuth
    # email sync), `record.email` is already the new address and
    # `record.unconfirmed_email` is nil by the time the mail renders, which
    # used to produce "changed from <new> to ." with a blank target.
    @old_email = opts[:to].presence || record.email
    @new_email = record.unconfirmed_email.presence || record.email
    super
  end

  private
    def set_custom_headers(mailer_action, mailer_args)
      return if self.message.class == ActionMailer::Base::NullMail

      # Devise mailer args are (record, token, opts) — replace records with
      # their ids and drop the confirmation token so no secret or PII ends
      # up in provider-side event metadata.
      safe_args = mailer_args.map do |argument|
        case argument
        when ActiveRecord::Base then argument.id
        when Hash then nil
        when String then "[FILTERED]"
        else argument
        end
      end.compact

      email_provider = self.message.delivery_method.settings[:address] == RESEND_SMTP_ADDRESS ? MailerInfo::EMAIL_PROVIDER_RESEND : MailerInfo::EMAIL_PROVIDER_SENDGRID
      custom_headers = MailerInfo.build_headers(mailer_class: self.class.name, mailer_method: mailer_action.to_s, mailer_args: safe_args, email_provider:)
      custom_headers.each do |name, value|
        headers[name] = value
      end
    end
end
