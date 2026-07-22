# frozen_string_literal: true

# Handles delivery-failure events (bounce / blocked / dropped) for account
# signup-confirmation emails (UserSignupMailer#confirmation_instructions).
#
# Why this exists: a single transient SMTP failure at signup time (receiving
# server timed out, greylisting, mailbox full, a brand-new business domain
# whose MX records were still propagating) puts the address on SendGrid's
# suppression list, after which every subsequent email — including
# confirmation resends — is silently dropped before send. The new seller can
# never confirm their account and has no idea why. See gumroad-private#1210.
#
# The fix: when the failure reason looks transient, the shared scheduler
# enqueues RetryTransientEmailFailureJob with an escalating backoff. The job
# removes the address from the suppression lists and re-sends the
# confirmation email. Hard failures ("user unknown", bad domain) and
# unrecognized reasons are never retried — retrying those damages sender
# reputation and cannot succeed. Spam reports and unsubscribes are consent
# signals, not deliverability problems, and are never touched.
class HandleEmailEventInfo::ForSignupConfirmationEmail
  def self.perform(email_event_info)
    TransientEmailFailureRetryScheduler.perform(
      email_event_info,
      mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION
    )
  end
end
