# frozen_string_literal: true

class UserSignupMailer < Devise::Mailer
  include RescueSmtpErrors
  helper MailerHelper
  helper ViteRails::TagHelpers
  helper ApplicationHelper
  layout "layouts/email"

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
end
