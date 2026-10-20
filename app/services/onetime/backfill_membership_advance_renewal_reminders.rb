# frozen_string_literal: true

# Schedules the 30-day advance notice for 12+ month subscriptions whose last purchase predates the
# deploy that started scheduling it. Later purchases schedule their own; the worker sends at most one
# advance notice per renewal, so overlap with them is harmless.
module Onetime
  class BackfillMembershipAdvanceRenewalReminders
    BATCH_SIZE = 500
    CURSOR_KEY = "onetime:backfill_membership_advance_renewal_reminders:cursor"
    RUNNING_KEY = "onetime:backfill_membership_advance_renewal_reminders:running"
    RUNNING_TTL = 2.minutes
    # A row that raises is retried on the next run instead of being skipped, but a row that fails
    # every time must not block every subscription ahead of it — after this many attempts it is
    # recorded as failed and stepped over.
    MAX_ATTEMPTS_PER_ROW = 3
    FAILED_IDS_KEY = "onetime:backfill_membership_advance_renewal_reminders:failed_ids"
    ATTEMPTS_KEY = "onetime:backfill_membership_advance_renewal_reminders:attempts"

    def self.process(deployed_at:, dry_run: false, batch_size: BATCH_SIZE, limit: nil)
      new(deployed_at:, dry_run:, batch_size:, limit:).process
    end

    def initialize(deployed_at:, dry_run: false, batch_size: BATCH_SIZE, limit: nil)
      @deployed_at = deployed_at
      @dry_run = dry_run
      @batch_size = batch_size
      @limit = limit
    end

    def process
      claim! unless @dry_run
      counts = { considered: 0, eligible: 0, scheduled: 0, skipped: 0, errors: 0 }
      start_after = $redis.get(CURSOR_KEY).to_i

      Subscription.where(cancelled_at: nil).where("id > ?", start_after).find_each(batch_size: @batch_size) do |subscription|
        break if @limit && counts[:considered] >= @limit
        counts[:considered] += 1

        begin
          advance_at = eligible?(subscription) ? subscription.advance_renewal_reminder_at : nil
          if advance_at && advance_at > Time.current
            counts[:eligible] += 1
            unless @dry_run
              RecurringChargeReminderWorker.perform_at(advance_at, subscription.id, RecurringChargeReminderWorker::ADVANCE)
              counts[:scheduled] += 1
            end
          else
            counts[:skipped] += 1
          end
        rescue => e
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipAdvanceRenewalReminders] failed on subscription #{subscription.id}: #{e.class}: #{e.message}")
          next if @dry_run

          # Do not advance past a row we failed on: leaving the cursor at the previous id makes the
          # next run retry this subscription instead of silently skipping its advance notice. A row
          # that fails on every attempt is recorded and stepped over, so one bad subscription cannot
          # stall the notices for every subscription with a higher id.
          attempts = $redis.hincrby(ATTEMPTS_KEY, subscription.id.to_s, 1)
          break if attempts < MAX_ATTEMPTS_PER_ROW

          $redis.sadd(FAILED_IDS_KEY, subscription.id)
          Rails.logger.error("[BackfillMembershipAdvanceRenewalReminders] gave up on subscription #{subscription.id} after #{attempts} attempts: #{e.class}: #{e.message}")
          advance!(subscription.id)
          next
        end

        advance!(subscription.id) unless @dry_run
      end

      Rails.logger.info("[BackfillMembershipAdvanceRenewalReminders] #{@dry_run ? 'dry run ' : ''}finished after id #{start_after}: #{counts.inspect}")
      counts
    ensure
      $redis.del(RUNNING_KEY) if @claimed
    end

    private
      def eligible?(subscription)
        subscription.send_renewal_reminders? &&
          subscription.last_purchase_at.present? &&
          subscription.last_purchase_at < @deployed_at &&
          subscription.alive?(include_pending_cancellation: false) &&
          !subscription.in_free_trial? &&
          !subscription.charges_completed? &&
          !(subscription.renewal_disabled_due_to_indian_card_mandate? && subscription.india_card_mandate_reliability_enabled?)
      end

      def claim!
        @claimed = $redis.set(RUNNING_KEY, Time.current.to_i, nx: true, ex: RUNNING_TTL.to_i)
        raise "BackfillMembershipAdvanceRenewalReminders is already running (#{RUNNING_KEY})" unless @claimed
      end

      def advance!(id)
        $redis.multi do |tx|
          tx.set(CURSOR_KEY, id)
          tx.expire(RUNNING_KEY, RUNNING_TTL.to_i)
          tx.hdel(ATTEMPTS_KEY, id.to_s)
        end
      end
  end
end
