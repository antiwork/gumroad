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
# The fix: when the failure reason looks transient, schedule
# RetryTransientEmailFailureJob with an escalating backoff. The job removes
# the address from the suppression lists and re-sends the confirmation email.
# Hard failures ("user unknown", bad domain) and unrecognized reasons are
# never retried — retrying those damages sender reputation and cannot
# succeed. Spam reports and unsubscribes are consent signals, not
# deliverability problems, and are never touched.
class HandleEmailEventInfo::ForSignupConfirmationEmail
  # Only genuine delivery failures qualify. EVENT_COMPLAINED (spam report)
  # is deliberately absent: a recipient marking us as spam must never trigger
  # a retry.
  RETRYABLE_EVENT_TYPES = [
    EmailEventInfo::EVENT_BOUNCED,
    EmailEventInfo::EVENT_BLOCKED,
    EmailEventInfo::EVENT_DROPPED,
  ].freeze

  attr_reader :email_event_info

  def self.perform(email_event_info)
    new(email_event_info).perform
  end

  def initialize(email_event_info)
    @email_event_info = email_event_info
  end

  def perform
    return unless email_event_info.type.in?(RETRYABLE_EVENT_TYPES)
    return if email_event_info.email.blank?

    classification = TransientEmailFailureClassifier.new(
      event_type: email_event_info.type,
      reason: email_event_info.reason
    ).classify

    unless classification == :transient
      # Fail closed: hard failures and reasons we don't recognize keep
      # today's behavior (the suppression stands, no retry).
      log("not retrying #{email_event_info.type} for #{email_event_info.email}: classified #{classification} (#{email_event_info.reason.inspect})")
      return
    end

    retry_record = TransientEmailFailureRetry.find_or_initialize_by(
      email: email_event_info.email,
      mail_kind: TransientEmailFailureRetry::SIGNUP_CONFIRMATION
    )

    # An old exhausted record shouldn't block retries forever — the cap is
    # per address per week, not once-ever.
    retry_record.assign_attributes(attempts: 0, retry_in_flight: false) if retry_record.persisted? && retry_record.stale?

    if retry_record.retry_in_flight?
      # A retry is already scheduled; providers can post several failure
      # events for the same send, and we only want one retry per failure.
      log("retry already scheduled for #{email_event_info.email}, ignoring duplicate #{email_event_info.type} event")
      return
    end

    if retry_record.attempts_exhausted?
      log("retries exhausted for #{email_event_info.email} (#{retry_record.attempts} attempts), leaving suppression in place")
      return
    end

    delay = retry_record.backoff_delay
    retry_record.last_reason = email_event_info.reason.to_s.first(1000)
    retry_record.retry_in_flight = true
    retry_record.save!

    RetryTransientEmailFailureJob.perform_in(delay, retry_record.id)
    log("scheduled retry ##{retry_record.attempts + 1} in #{delay.inspect} for #{email_event_info.email} (reason: #{retry_record.last_reason.inspect})")
  end

  private
    def log(message)
      Rails.logger.info("[TransientEmailRetry] #{message}")
    end
end
