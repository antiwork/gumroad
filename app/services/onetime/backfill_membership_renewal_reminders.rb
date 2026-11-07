# frozen_string_literal: true

# Schedules the renewal reminder for subscriptions whose last purchase predates the
# membership_renewal_reminders flip; later purchases already scheduled their own, so
# including them would email the buyer twice.
#
# Run it only once every web and Sidekiq process is on the code that marks final reminders: the worker
# skips a renewal only if its marker exists, so a reminder sent before that (or a crash between the
# enqueue and the marker) can still be sent again. Progress lives in a Redis cursor so a retry resumes
# after the last row handled and a finished run is a no-op on rerun.
module Onetime
  class BackfillMembershipRenewalReminders
    class EnqueueFailed < StandardError; end
    # RUNNING_KEY expired and another run claimed it; this run must stop writing shared state.
    class LeaseLost < StandardError; end

    BATCH_SIZE = 500
    CURSOR_KEY = "onetime:backfill_membership_renewal_reminders:cursor"
    RUNNING_KEY = "onetime:backfill_membership_renewal_reminders:running"
    # Refreshed every row, so a killed worker frees it quickly enough for its retry.
    RUNNING_TTL = 2.minutes
    # If the flag is ever cycled off and on again, pass the new moment as enabled_before.
    FLAG_ENABLED_AT = Time.utc(2026, 9, 26, 15, 0, 24).freeze
    # Reminders already past their lead time would otherwise all enqueue at once.
    DUE_NOW_SPREAD = 1.hour
    # A row that raises is retried on the next run instead of being skipped; after this many attempts it
    # is recorded as failed and stepped over so it cannot block every subscription after it.
    MAX_ATTEMPTS_PER_ROW = 3
    FAILED_IDS_KEY = "onetime:backfill_membership_renewal_reminders:failed_ids"
    ATTEMPTS_KEY = "onetime:backfill_membership_renewal_reminders:attempts"
    # Same owner-token scripts as the advance notice backfill; each acts only while RUNNING_KEY holds this run's token.
    RENEW_SCRIPT = BackfillMembershipAdvanceRenewalReminders::RENEW_SCRIPT
    ADVANCE_SCRIPT = BackfillMembershipAdvanceRenewalReminders::ADVANCE_SCRIPT
    RECORD_FAILURE_SCRIPT = BackfillMembershipAdvanceRenewalReminders::RECORD_FAILURE_SCRIPT
    RELEASE_SCRIPT = BackfillMembershipAdvanceRenewalReminders::RELEASE_SCRIPT

    def self.process(dry_run: false, batch_size: BATCH_SIZE, limit: nil, enabled_before: FLAG_ENABLED_AT)
      new(dry_run:, batch_size:, limit:, enabled_before:).process
    end

    def initialize(dry_run: false, batch_size: BATCH_SIZE, limit: nil, enabled_before: FLAG_ENABLED_AT)
      @dry_run = dry_run
      @batch_size = batch_size
      @limit = limit
      @enabled_before = enabled_before
    end

    def process
      claim! unless @dry_run
      counts = { considered: 0, eligible: 0, scheduled: 0, skipped: 0, errors: 0, due_immediately: 0 }
      start_after = $redis.get(CURSOR_KEY).to_i

      Subscription.where(cancelled_at: nil).where("id > ?", start_after).find_each(batch_size: @batch_size) do |subscription|
        break if @limit && counts[:considered] >= @limit
        counts[:considered] += 1

        begin
          if eligible?(subscription)
            counts[:eligible] += 1
            schedule(subscription, counts)
          else
            counts[:skipped] += 1
          end
        rescue LeaseLost
          raise
        rescue => e
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipRenewalReminders] failed on subscription #{subscription.id}: #{e.class}: #{e.message}")
          next if @dry_run

          # Leave the cursor before a failed row so the next run retries it.
          attempts = record_failure!(subscription.id)
          break if attempts < MAX_ATTEMPTS_PER_ROW

          Rails.logger.error("[BackfillMembershipRenewalReminders] gave up on subscription #{subscription.id} after #{attempts} attempts: #{e.class}: #{e.message}")
          next
        end

        # Per row, so a crash re-schedules at most the row in flight.
        advance!(subscription.id) unless @dry_run
        Rails.logger.info("[BackfillMembershipRenewalReminders] progress #{counts.inspect}") if (counts[:considered] % 10_000).zero?
      end

      Rails.logger.info("[BackfillMembershipRenewalReminders] #{@dry_run ? 'dry run ' : ''}finished after id #{start_after}: #{counts.inspect}")
      counts
    ensure
      $redis.eval(RELEASE_SCRIPT, keys: [RUNNING_KEY], argv: [@token]) if @claimed
    end

    private
      # Not send_renewal_reminder_at: it floors at Time.current, which hides the due-now rows.
      def schedule(subscription, counts)
        renews_at = subscription.renews_at
        remind_at = renews_at - BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence)
        now = Time.current

        if remind_at <= now
          counts[:due_immediately] += 1
          # Spread, but never past half the time left before the charge.
          remind_at = now + rand * ((renews_at - now) / 2).clamp(0, DUE_NOW_SPREAD.to_i)
        end
        return if @dry_run

        renew!
        enqueued = RecurringChargeReminderWorker.perform_at(remind_at, subscription.id)
        raise EnqueueFailed, "perform_at returned #{enqueued.inspect}" unless enqueued
        counts[:scheduled] += 1
      end

      # RecurringChargeReminderWorker#perform's guards, plus the purchase cutoff it can't see.
      # No last purchase means no renewal date to derive (renews_at raises).
      def eligible?(subscription)
        subscription.send_renewal_reminders? &&
          subscription.last_purchase_at.present? &&
          subscription.last_purchase_at < @enabled_before &&
          subscription.alive?(include_pending_cancellation: false) &&
          !subscription.in_free_trial? &&
          !subscription.charges_completed? &&
          !(subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?) &&
          subscription.renews_at > Time.current
      end

      def claim!
        @token = SecureRandom.hex(16)
        @claimed = $redis.set(RUNNING_KEY, @token, nx: true, ex: RUNNING_TTL.to_i)
        raise "BackfillMembershipRenewalReminders is already running (#{RUNNING_KEY})" unless @claimed
      end

      def renew!
        lease_lost! unless $redis.eval(RENEW_SCRIPT, keys: [RUNNING_KEY], argv: [@token, RUNNING_TTL.to_i]) == 1
      end

      def advance!(id)
        lease_lost! unless $redis.eval(ADVANCE_SCRIPT, keys: [RUNNING_KEY, CURSOR_KEY, ATTEMPTS_KEY], argv: [@token, RUNNING_TTL.to_i, id]) == 1
      end

      # Counts the attempt and, at the cap, records the row as failed and steps the cursor past it.
      def record_failure!(id)
        attempts = $redis.eval(RECORD_FAILURE_SCRIPT, keys: [RUNNING_KEY, ATTEMPTS_KEY, FAILED_IDS_KEY, CURSOR_KEY], argv: [@token, RUNNING_TTL.to_i, id, MAX_ATTEMPTS_PER_ROW])
        lease_lost! if attempts.negative?
        attempts
      end

      def lease_lost!
        Rails.logger.error("[BackfillMembershipRenewalReminders] lost #{RUNNING_KEY} to another run; stopping without further writes")
        raise LeaseLost, "#{RUNNING_KEY} is held by another run"
      end
  end
end
