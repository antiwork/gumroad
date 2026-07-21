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
      # increment also means concurrent runs can never lose a count.
      claimed = TransientEmailFailureRetry
        .where(id: retry_record.id, retry_in_flight: true)
        .update_all(["attempts = attempts + 1, retry_in_flight = false, updated_at = ?", Time.current])
      if claimed.zero?
        log("skipping resend for #{retry_record.email}: retry already handled (no in-flight claim)")
        return
      end
      retry_record.reload
      # The attempts value our increment produced. Used below to make the
      # failure rollback a compare-and-swap: it only fires while OUR
      # increment is the latest unrevoked change to the counter.
      claimed_attempts = retry_record.attempts

      begin
        # Unsuppress before re-sending, or SendGrid silently drops the send.
        # Only the deliverability lists — never spam_reports or unsubscribes.
        EmailSuppressionManager.new(retry_record.email).remove_from_lists([:bounces, :blocks])

        user.send_confirmation_instructions
      rescue => e
        # The attempt was recorded but nothing was sent (e.g. the SendGrid
        # suppression API errored). Un-record it — give the attempt back and
        # restore the in-flight claim — then re-raise so Sidekiq's own retry
        # re-runs this job and the claim guard above lets it through. Without
        # this, the Sidekiq re-run would match zero rows on the guard and
        # exit, permanently losing the attempt with no email sent.
        #
        # The rollback is a compare-and-swap keyed on the attempts value our
        # own increment produced. That value uniquely fingerprints "our
        # increment is the latest unrevoked change": any newer job that
        # consumed a replacement claim pushed the counter higher, and the
        # counter only comes back down when that job's own rollback undoes
        # its own increment. Two races this has to survive:
        #
        # 1. A fresh provider failure event re-claims the row (sets
        #    retry_in_flight back to true, counter unchanged) between our
        #    claim and this rescue. The guard still matches — the decrement
        #    correctly un-records our failed attempt, and setting
        #    retry_in_flight = true is a no-op on the already-true flag. The
        #    newer scheduled retry (or our Sidekiq re-run, whichever wins the
        #    claim) performs the one send.
        #
        # 2. That newer scheduled retry has ALREADY consumed the replacement
        #    claim and is mid-send (counter is ours + 1, flag false). The
        #    guard matches zero rows and we deliberately do nothing — an
        #    unguarded rollback here would decrement the newer job's attempt
        #    and recreate a claim that our Sidekiq re-run could consume,
        #    sending a duplicate confirmation. The cost of skipping is that
        #    our failed attempt stays counted (a one-off over-count in a
        #    narrow double-race window), which is the safe direction: it can
        #    only end retries one attempt early, never double-send.
        #
        # If Sidekiq's retries are exhausted with the claim restored, the
        # claim dangles until CLAIM_EXPIRY, after which the next failure
        # event for this address releases it and scheduling resumes.
        TransientEmailFailureRetry
          .where(id: retry_record.id, attempts: claimed_attempts)
          .update_all(["attempts = attempts - 1, retry_in_flight = true, updated_at = ?", Time.current])
        raise e
      end

      log("re-sent signup confirmation to #{retry_record.email} (attempt #{retry_record.attempts}/#{TransientEmailFailureRetry::MAX_ATTEMPTS}, last failure: #{retry_record.last_reason.inspect})")
    end

    def log(message)
      Rails.logger.info("[TransientEmailRetry] #{message}")
    end
end
