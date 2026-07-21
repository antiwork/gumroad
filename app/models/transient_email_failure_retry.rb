# frozen_string_literal: true

# Tracks auto-retry attempts for account-critical emails that failed with a
# transient SMTP error (see TransientEmailFailureClassifier and
# HandleEmailEventInfo::ForSignupConfirmationEmail). One row per
# (email, mail_kind) pair; the attempts counter enforces the
# reputation-protecting cap of MAX_ATTEMPTS retries per address per
# ATTEMPTS_WINDOW.
class TransientEmailFailureRetry < ApplicationRecord
  SIGNUP_CONFIRMATION = "signup_confirmation"
  MAIL_KINDS = [SIGNUP_CONFIRMATION].freeze

  # Retry schedule: the Nth retry (indexed by the attempts counter at enqueue
  # time) is delayed by BACKOFF_SCHEDULE[N]. Spread out so a slow DNS
  # propagation or a full mailbox has real time to resolve before we give up.
  BACKOFF_SCHEDULE = [15.minutes, 2.hours, 12.hours].freeze
  MAX_ATTEMPTS = BACKOFF_SCHEDULE.size

  # After this long without a new failure the attempts counter resets, so an
  # address that had an unrelated transient failure long ago isn't
  # permanently locked out of retries. This is also what makes MAX_ATTEMPTS a
  # "per address per week" cap rather than a once-ever cap.
  ATTEMPTS_WINDOW = 7.days

  validates :email, presence: true
  validates :mail_kind, presence: true, inclusion: { in: MAIL_KINDS }

  def attempts_exhausted?
    attempts >= MAX_ATTEMPTS
  end

  def backoff_delay
    BACKOFF_SCHEDULE[attempts] || BACKOFF_SCHEDULE.last
  end

  def stale?
    updated_at <= ATTEMPTS_WINDOW.ago
  end

  # A retry claim (retry_in_flight = true) normally lasts at most the longest
  # backoff delay before the job runs and clears it. If the claim is older
  # than that (plus generous slack for queue latency), the scheduled job was
  # lost — e.g. the process died after saving the claim but before enqueuing —
  # and holding the claim would block retries for this address forever.
  CLAIM_EXPIRY = BACKOFF_SCHEDULE.last + 6.hours

  def claim_expired?
    retry_in_flight? && updated_at <= CLAIM_EXPIRY.ago
  end
end
