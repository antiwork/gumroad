# frozen_string_literal: true

# Shared scheduling core for retrying account-critical emails that failed
# with a transient SMTP error (see TransientEmailFailureClassifier for the
# transient-vs-hard decision and gumroad-private#1210 for the incident that
# motivated all of this).
#
# Callers (the per-mail-kind HandleEmailEventInfo handlers) hand this class a
# failure event plus the mail_kind to retry; it classifies the reason,
# fail-closed, and schedules RetryTransientEmailFailureJob with an escalating
# backoff when — and only when — the failure looks temporary. All the
# concurrency care lives here so each new mail kind doesn't have to re-derive
# it: the unique (email, mail_kind) row absorbs duplicate webhook deliveries,
# the row lock makes the guard-then-claim sequence atomic, and a claim that
# can no longer correspond to a live job (process died before enqueue) is
# released instead of blocking retries forever.
class TransientEmailFailureRetryScheduler
  # Only genuine delivery failures qualify. EVENT_COMPLAINED (spam report)
  # is deliberately absent: a recipient marking us as spam must never trigger
  # a retry.
  RETRYABLE_EVENT_TYPES = [
    EmailEventInfo::EVENT_BOUNCED,
    EmailEventInfo::EVENT_BLOCKED,
    EmailEventInfo::EVENT_DROPPED,
  ].freeze

  attr_reader :email_event_info, :mail_kind, :purchase_id, :charge_id

  # purchase_id / charge_id pin the retry to the specific record whose email
  # failed (receipts); they're nil for account-level mail like signup
  # confirmations, where the address alone identifies what to re-send. Each
  # pinned failure becomes an entry on the retry row's pending_targets list,
  # so several distinct receipts failing for one address all get re-sent by
  # the single scheduled retry.
  def self.perform(email_event_info, mail_kind:, purchase_id: nil, charge_id: nil)
    new(email_event_info, mail_kind:, purchase_id:, charge_id:).perform
  end

  def initialize(email_event_info, mail_kind:, purchase_id: nil, charge_id: nil)
    @email_event_info = email_event_info
    @mail_kind = mail_kind
    @purchase_id = purchase_id
    @charge_id = charge_id
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

    # create_or_find_by! leans on the unique (email, mail_kind) index so two
    # webhook workers racing on the same address both end up with the same
    # row instead of one of them raising RecordNotUnique.
    retry_record = TransientEmailFailureRetry.create_or_find_by!(
      email: email_event_info.email,
      mail_kind:
    )

    delay = nil
    # The guard-then-claim sequence below must be atomic: without the row
    # lock, two workers processing duplicate failure events could both see
    # retry_in_flight = false, both pass the guards, and both schedule a
    # retry — double-sending the email and over-counting attempts.
    retry_record.with_lock do
      # An old exhausted record shouldn't block retries forever — the cap is
      # per address per week, not once-ever.
      retry_record.assign_attributes(attempts: 0, retry_in_flight: false) if retry_record.stale?

      # A claim can be left dangling if the process died between saving the
      # claim and enqueuing the job. Claims older than the longest possible
      # backoff (plus slack) can't correspond to a live scheduled job, so
      # release them rather than blocking retries for this address forever.
      retry_record.retry_in_flight = false if retry_record.claim_expired?

      if retry_record.retry_in_flight?
        # A retry is already scheduled. Providers can post several failure
        # events for the same send — those are true duplicates, and we keep
        # the single scheduled retry. But a DIFFERENT receipt failing for the
        # same address (say two separate purchases to one email both bounce)
        # must not be silently dropped: add it to the row's pending target
        # list so the already-scheduled job resends it too. The job reads
        # pending_targets from the row when it fires, so no extra enqueue is
        # needed, and the attempts cap stays per-address (one attempt covers
        # however many receipts are pending for the address).
        if pending_target.present? && !Array(retry_record.pending_targets).include?(pending_target)
          retry_record.update!(
            pending_targets: Array(retry_record.pending_targets) + [pending_target],
            last_reason: email_event_info.reason.to_s.first(1000)
          )
          log("added another failed receipt to the pending retry for #{email_event_info.email}")
        else
          log("retry already scheduled for #{email_event_info.email}, ignoring duplicate #{email_event_info.type} event")
        end
        next
      end

      if retry_record.attempts_exhausted?
        log("retries exhausted for #{email_event_info.email} (#{retry_record.attempts} attempts), leaving suppression in place")
        next
      end

      delay = retry_record.backoff_delay
      retry_record.last_reason = email_event_info.reason.to_s.first(1000)
      # Queue THIS failure's receipt for the retry (deduped — the provider
      # can post several failure events for one send). Targets left over from
      # an earlier attempt stay on the list so they're retried too.
      if pending_target.present?
        retry_record.pending_targets = Array(retry_record.pending_targets) | [pending_target]
      end
      retry_record.retry_in_flight = true
      retry_record.save!
    end
    return if delay.nil?

    begin
      RetryTransientEmailFailureJob.perform_in(delay, retry_record.id)
    rescue => e
      # The claim was saved but no job exists (e.g. Redis was down). Release
      # the claim so the webhook retry — or the provider's next failure
      # event — can schedule the retry instead of treating it as a duplicate.
      retry_record.update!(retry_in_flight: false)
      raise e
    end
    log("scheduled retry ##{retry_record.attempts + 1} in #{delay.inspect} for #{email_event_info.email} (reason: #{retry_record.last_reason.inspect})")
  end

  private
    # The specific receipt this failure event is for, in the shape stored on
    # the retry row's pending_targets list (string keys — the column is JSON,
    # so that's what a database round-trip returns). Nil for address-level
    # mail kinds like signup confirmations, where nothing needs pinning.
    def pending_target
      if charge_id.present?
        { "charge_id" => charge_id.to_i }
      elsif purchase_id.present?
        { "purchase_id" => purchase_id.to_i }
      end
    end

    def log(message)
      Rails.logger.info("[TransientEmailRetry] #{message}")
    end
end
