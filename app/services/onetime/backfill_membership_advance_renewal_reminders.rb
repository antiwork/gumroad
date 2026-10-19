# frozen_string_literal: true

# Schedules the 30-day advance notice for 12+ month subscriptions bought before the release. Pass
# rollout_finished_at once every web and Sidekiq process runs the new code, since old processes schedule
# without the notice until then; the worker dedupes per renewal, so overlap is harmless.
module Onetime
  class BackfillMembershipAdvanceRenewalReminders
    class EnqueueFailed < StandardError; end

    BATCH_SIZE = 500
    CURSOR_KEY = "onetime:backfill_membership_advance_renewal_reminders:cursor"
    RUNNING_KEY = "onetime:backfill_membership_advance_renewal_reminders:running"
    RUNNING_TTL = 2.minutes

    def self.process(rollout_finished_at:, dry_run: false, batch_size: BATCH_SIZE, limit: nil)
      new(rollout_finished_at:, dry_run:, batch_size:, limit:).process
    end

    def initialize(rollout_finished_at:, dry_run: false, batch_size: BATCH_SIZE, limit: nil)
      raise ArgumentError, "rollout_finished_at must be a time, got #{rollout_finished_at.inspect}" unless rollout_finished_at.acts_like?(:time)
      raise ArgumentError, "rollout_finished_at must be in the past, got #{rollout_finished_at}" if rollout_finished_at > Time.current

      @rollout_finished_at = rollout_finished_at
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
              enqueued = RecurringChargeReminderWorker.perform_at(advance_at, subscription.id, RecurringChargeReminderWorker::ADVANCE)
              raise EnqueueFailed, "perform_at returned #{enqueued.inspect}" unless enqueued
              counts[:scheduled] += 1
            end
          else
            counts[:skipped] += 1
          end
        rescue => e
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipAdvanceRenewalReminders] failed on subscription #{subscription.id}: #{e.class}: #{e.message}")
          # Do not advance past a row we failed on: leaving the cursor at the previous id makes the
          # next run retry this subscription instead of silently skipping its advance notice.
          break unless @dry_run
        end

        advance!(subscription.id) unless @dry_run
      end

      Rails.logger.info("[BackfillMembershipAdvanceRenewalReminders] #{@dry_run ? 'dry run ' : ''}#{counts[:errors].zero? ? 'finished' : 'stopped'} after id #{start_after}: #{counts.inspect}")
      counts
    ensure
      $redis.del(RUNNING_KEY) if @claimed
    end

    private
      def eligible?(subscription)
        subscription.send_renewal_reminders? &&
          subscription.last_purchase_at.present? &&
          subscription.last_purchase_at < @rollout_finished_at &&
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
        end
      end
  end
end
