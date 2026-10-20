# frozen_string_literal: true

# Schedules the 30-day advance notice for 12+ month subscriptions bought before the release. Pass
# rollout_finished_at once every web and Sidekiq process runs the new code, since old processes schedule
# without the notice until then; the worker dedupes per renewal, so overlap is harmless.
module Onetime
  class BackfillMembershipAdvanceRenewalReminders
    class EnqueueFailed < StandardError; end
    # RUNNING_KEY expired and another run claimed it; this run must stop writing shared state.
    class LeaseLost < StandardError; end

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

    # Each script acts only while RUNNING_KEY still holds this run's token, in one atomic step.
    RENEW_SCRIPT = <<~LUA
      if redis.call("GET", KEYS[1]) ~= ARGV[1] then return 0 end
      return redis.call("EXPIRE", KEYS[1], ARGV[2])
    LUA
    ADVANCE_SCRIPT = <<~LUA
      if redis.call("GET", KEYS[1]) ~= ARGV[1] then return 0 end
      redis.call("SET", KEYS[2], ARGV[3])
      redis.call("HDEL", KEYS[3], ARGV[3])
      return redis.call("EXPIRE", KEYS[1], ARGV[2])
    LUA
    RECORD_FAILURE_SCRIPT = <<~LUA
      if redis.call("GET", KEYS[1]) ~= ARGV[1] then return -1 end
      local attempts = redis.call("HINCRBY", KEYS[2], ARGV[3], 1)
      if attempts >= tonumber(ARGV[4]) then
        redis.call("SADD", KEYS[3], ARGV[3])
        redis.call("SET", KEYS[4], ARGV[3])
        redis.call("HDEL", KEYS[2], ARGV[3])
      end
      redis.call("EXPIRE", KEYS[1], ARGV[2])
      return attempts
    LUA
    RELEASE_SCRIPT = <<~LUA
      if redis.call("GET", KEYS[1]) == ARGV[1] then return redis.call("DEL", KEYS[1]) end
      return 0
    LUA

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
              renew!
              enqueued = RecurringChargeReminderWorker.perform_at(advance_at, subscription.id, RecurringChargeReminderWorker::ADVANCE)
              raise EnqueueFailed, "perform_at returned #{enqueued.inspect}" unless enqueued
              counts[:scheduled] += 1
            end
          else
            counts[:skipped] += 1
          end
        rescue LeaseLost
          raise
        rescue => e
          counts[:errors] += 1
          Rails.logger.warn("[BackfillMembershipAdvanceRenewalReminders] failed on subscription #{subscription.id}: #{e.class}: #{e.message}")
          next if @dry_run

          # Do not advance past a row we failed on: leaving the cursor at the previous id makes the
          # next run retry this subscription instead of silently skipping its advance notice. A row
          # that fails on every attempt is recorded and stepped over, so one bad subscription cannot
          # stall the notices for every subscription with a higher id.
          attempts = record_failure!(subscription.id)
          break if attempts < MAX_ATTEMPTS_PER_ROW

          Rails.logger.error("[BackfillMembershipAdvanceRenewalReminders] gave up on subscription #{subscription.id} after #{attempts} attempts: #{e.class}: #{e.message}")
          next
        end

        advance!(subscription.id) unless @dry_run
      end

      Rails.logger.info("[BackfillMembershipAdvanceRenewalReminders] #{@dry_run ? 'dry run ' : ''}finished after id #{start_after}: #{counts.inspect}")
      counts
    ensure
      $redis.eval(RELEASE_SCRIPT, keys: [RUNNING_KEY], argv: [@token]) if @claimed
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
        @token = SecureRandom.hex(16)
        @claimed = $redis.set(RUNNING_KEY, @token, nx: true, ex: RUNNING_TTL.to_i)
        raise "BackfillMembershipAdvanceRenewalReminders is already running (#{RUNNING_KEY})" unless @claimed
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
        Rails.logger.error("[BackfillMembershipAdvanceRenewalReminders] lost #{RUNNING_KEY} to another run; stopping without further writes")
        raise LeaseLost, "#{RUNNING_KEY} is held by another run"
      end
  end
end
