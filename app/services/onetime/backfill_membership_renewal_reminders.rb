# frozen_string_literal: true

# One-time backfill: schedule the pre-renewal reminder email for subscriptions that
# were already active when `membership_renewal_reminders` was turned on globally.
#
# Subscription#schedule_renewal_reminder is only ever called from the purchase flow, so
# it fires when a subscription is created or rebilled. Turning the flag on therefore
# covers new subscriptions immediately, but not the renewal a subscription was already
# heading into — that reminder was never scheduled, because the flag was off the last
# time a purchase touched it. This walks the existing population once and schedules that
# reminder; every later cycle is handled by the normal purchase path.
#
# So the run is limited to subscriptions whose last purchase predates the flag flip
# (`enabled_before`): anything purchased after it already got a reminder scheduled, and
# scheduling a second one would email that buyer twice for the same renewal. Subscriptions
# that rebill between the flip and this run are covered by their own rebill, so skipping
# them here loses nothing.
#
# Nothing is emailed early: Subscription#schedule_renewal_reminder enqueues a future-dated
# job derived from the subscription's own renewal date, so a reminder lands at its usual
# lead time (BasePrice::Recurrence.renewal_reminder_email_days) whenever this is run.
#
# Not idempotent: the set of scheduled jobs can't be queried per subscription cheaply
# enough to inspect for one, so a second live run would enqueue a second reminder per
# subscription. The run claims a Redis key on the way in, so a rerun fails loudly instead
# of double-emailing buyers. `dry_run: true` reports the numbers without claiming the key
# or scheduling anything.
module Onetime
  class BackfillMembershipRenewalReminders
    BATCH_SIZE = 500
    LOCK_KEY = "onetime:backfill_membership_renewal_reminders:v1"
    LOCK_TTL = 90.days
    # When membership_renewal_reminders was enabled globally in production. Only needed
    # for this one run; if the flag is ever cycled off and on again, pass the new moment.
    FLAG_ENABLED_AT = Time.utc(2026, 9, 26, 15, 0, 24).freeze

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

      counts = { considered: 0, eligible: 0, scheduled: 0, skipped: 0, errors: 0 }
      due_immediately = 0
      now = Time.current

      Subscription.where(cancelled_at: nil).find_each(batch_size: @batch_size) do |subscription|
        break if @limit && counts[:considered] >= @limit
        counts[:considered] += 1

        begin
          unless eligible?(subscription)
            counts[:skipped] += 1
            next
          end

          counts[:eligible] += 1
          # A reminder whose lead time already passed runs as soon as it is scheduled;
          # count those separately so the dry run states the real one-off email volume.
          due_immediately += 1 if subscription.send_renewal_reminder_at <= now

          unless @dry_run
            subscription.schedule_renewal_reminder
            counts[:scheduled] += 1
          end
        rescue => e
          # One malformed row (legacy data, a dead link) must not abort the run; the rest
          # of the population still needs its reminder.
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipRenewalReminders] skipped subscription #{subscription.id}: #{e.class}: #{e.message}")
        end

        Rails.logger.info("[BackfillMembershipRenewalReminders] progress #{counts.inspect}") if (counts[:considered] % 10_000).zero?
      end

      summary = counts.merge(due_immediately:)
      Rails.logger.info("[BackfillMembershipRenewalReminders] #{@dry_run ? 'dry run ' : ''}finished: #{summary.inspect}")
      summary
    end

    private
      # Mirrors the guards in RecurringChargeReminderWorker#perform, so this only schedules
      # reminders that would actually send. The purchase cutoff is the part the worker can't
      # see: a purchase after the flip already scheduled its own reminder, and a subscription
      # with no last purchase has nothing to derive one from (end_time_of_subscription
      # dereferences the last purchase and raises).
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
        claimed = $redis.set(LOCK_KEY, Time.current.to_i, nx: true, ex: LOCK_TTL.to_i)
        raise "BackfillMembershipRenewalReminders already ran or is running (#{LOCK_KEY}); pass dry_run: true to inspect without scheduling" unless claimed
      end
  end
end
