# frozen_string_literal: true

# Re-sends an account-critical email whose previous delivery failed with a
# transient SMTP error (see HandleEmailEventInfo::ForSignupConfirmationEmail
# for how these get scheduled, and gumroad-private#1210 for why).
#
# For the retry to actually leave the building, the address must first be
# removed from SendGrid's bounce/block suppression lists — otherwise SendGrid
# drops the re-send before it's attempted, which is exactly the silent
# failure mode we're fixing. Spam-report and global-unsubscribe lists are
# consent surfaces and are never touched.
#
# If the retry fails again, the provider posts a fresh failure event and the
# webhook handler schedules the next attempt with a longer backoff, up to
# TransientEmailFailureRetry::MAX_ATTEMPTS.
class RetryTransientEmailFailureJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(transient_email_failure_retry_id)
    retry_record = TransientEmailFailureRetry.find_by(id: transient_email_failure_retry_id)
    return if retry_record.nil?

    case retry_record.mail_kind
    when TransientEmailFailureRetry::SIGNUP_CONFIRMATION
      retry_signup_confirmation(retry_record)
    end
  end

  private
    def retry_signup_confirmation(retry_record)
      # The confirmation email may target either the account email (initial
      # signup) or a pending new address (email change re-confirmation).
      user = User.alive.where("email = ? OR unconfirmed_email = ?", retry_record.email, retry_record.email).last
      if user.nil? || (user.confirmed? && user.unconfirmed_email.blank?)
        # Nothing to re-send: the user confirmed in the meantime (or the
        # account is gone). Clear the in-flight flag so a future failure for
        # this address can schedule retries again.
        retry_record.update!(retry_in_flight: false)
        log("skipping resend for #{retry_record.email}: no unconfirmed user found")
        return
      end

      # Record the attempt BEFORE sending, in one atomic UPDATE guarded on
      # the in-flight flag. This makes the resend at-most-once per scheduled
      # retry: if this job crashes after sending and Sidekiq re-runs it, the
      # guard matches zero rows and we don't send a duplicate. The atomic
      # increment also means concurrent runs can never lose a count. The
      # trade-off (crash between this update and the send means that attempt
      # sends nothing) is the safe direction — the provider posts a fresh
      # failure event for a genuinely undelivered email, which schedules the
      # next attempt.
      claimed = TransientEmailFailureRetry
        .where(id: retry_record.id, retry_in_flight: true)
        .update_all(["attempts = attempts + 1, retry_in_flight = false, updated_at = ?", Time.current])
      if claimed.zero?
        log("skipping resend for #{retry_record.email}: retry already handled (no in-flight claim)")
        return
      end
      retry_record.reload

      # Unsuppress before re-sending, or SendGrid silently drops the send.
      # Only the deliverability lists — never spam_reports or unsubscribes.
      EmailSuppressionManager.new(retry_record.email).remove_from_lists([:bounces, :blocks])

      user.send_confirmation_instructions

      log("re-sent signup confirmation to #{retry_record.email} (attempt #{retry_record.attempts}/#{TransientEmailFailureRetry::MAX_ATTEMPTS}, last failure: #{retry_record.last_reason.inspect})")
    end

    def log(message)
      Rails.logger.info("[TransientEmailRetry] #{message}")
    end
end
