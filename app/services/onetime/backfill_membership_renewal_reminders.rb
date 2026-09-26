# frozen_string_literal: true

# Schedules the renewal reminder for subscriptions whose last purchase predates the
# membership_renewal_reminders flip; later purchases already scheduled their own, so
# including them would email the buyer twice.
#
# Not idempotent per row, so progress lives in a Redis cursor: a retry resumes after the
# last row handled and a finished run is a no-op on rerun.
module Onetime
  class BackfillMembershipRenewalReminders
    BATCH_SIZE = 500
    CURSOR_KEY = "onetime:backfill_membership_renewal_reminders:cursor"
    RUNNING_KEY = "onetime:backfill_membership_renewal_reminders:running"
    # Refreshed every row, so a killed worker frees it quickly enough for its retry.
    RUNNING_TTL = 2.minutes
    # If the flag is ever cycled off and on again, pass the new moment as enabled_before.
    FLAG_ENABLED_AT = Time.utc(2026, 9, 26, 15, 0, 24).freeze
    # Reminders already past their lead time would otherwise all enqueue at once.
    DUE_NOW_SPREAD = 1.hour

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
        rescue => e
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipRenewalReminders] skipped subscription #{subscription.id}: #{e.class}: #{e.message}")
        end

        # Per row, so a crash re-schedules at most the row in flight.
        advance!(subscription.id) unless @dry_run
        Rails.logger.info("[BackfillMembershipRenewalReminders] progress #{counts.inspect}") if (counts[:considered] % 10_000).zero?
      end

      Rails.logger.info("[BackfillMembershipRenewalReminders] #{@dry_run ? 'dry run ' : ''}finished after id #{start_after}: #{counts.inspect}")
      counts
    ensure
      $redis.del(RUNNING_KEY) if @claimed
    end

    private
      # Not send_renewal_reminder_at: it floors at Time.current, which hides the due-now rows.
      def schedule(subscription, counts)
        renews_at = subscription.end_time_of_subscription
        remind_at = renews_at - BasePrice::Recurrence.renewal_reminder_email_days(subscription.recurrence)
        now = Time.current

        if remind_at <= now
          counts[:due_immediately] += 1
          # Spread, but never past half the time left before the charge.
          remind_at = now + rand * ((renews_at - now) / 2).clamp(0, DUE_NOW_SPREAD.to_i)
        end
        return if @dry_run

        RecurringChargeReminderWorker.perform_at(remind_at, subscription.id)
        counts[:scheduled] += 1
      end

      # RecurringChargeReminderWorker#perform's guards, plus the purchase cutoff it can't see.
      # No last purchase means no renewal date to derive (end_time_of_subscription raises).
      def eligible?(subscription)
        subscription.send_renewal_reminders? &&
          subscription.last_purchase_at.present? &&
          subscription.last_purchase_at < @enabled_before &&
          subscription.alive?(include_pending_cancellation: false) &&
          !subscription.in_free_trial? &&
          !subscription.charges_completed? &&
          !(subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?)
      end

      def claim!
        @claimed = $redis.set(RUNNING_KEY, Time.current.to_i, nx: true, ex: RUNNING_TTL.to_i)
        raise "BackfillMembershipRenewalReminders is already running (#{RUNNING_KEY})" unless @claimed
      end

      def advance!(id)
        $redis.multi do |tx|
          tx.set(CURSOR_KEY, id)
          tx.expire(RUNNING_KEY, RUNNING_TTL.to_i)
        end
      end
  end
end
