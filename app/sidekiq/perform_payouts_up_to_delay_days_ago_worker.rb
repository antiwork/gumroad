# frozen_string_literal: true

class PerformPayoutsUpToDelayDaysAgoWorker
  include Sidekiq::Job
  # retry: 3 (was 0): with no retries, a single transient
  # ActiveRecord::StatementTimeout on the `holding_balance` query sends the whole weekly
  # batch straight to the dead set with no alert, leaving every seller in the affected
  # bucket unpaid until the next weekly run. Retrying is safe: per-user payout jobs are
  # deduplicated by their `until_executed` lock while queued, and once a user's balances
  # leave `unpaid`, Payouts.create_payment no-ops for that user.
  sidekiq_options retry: 3, queue: :critical, lock: :until_executed

  sidekiq_retries_exhausted do |job, exception|
    payout_processor_type, bank_account_types = job["args"]
    AccountingMailer.payout_batch_failed(payout_processor_type, bank_account_types, exception.class.name, exception.message).deliver_later
    ErrorNotifier.notify(exception, payout_processor_type:, bank_account_types:)
  end

  # Both scripts below run as single atomic Redis operations (a Lua script can't be
  # interleaved with other commands). The atomicity matters for correctness, not tidiness:
  #
  # Raising the flag: if INCR and EXPIRE were two separate calls, a transient Redis error
  # between them could leave a positive counter with no TTL — the healthcheck would then
  # report "payouts in flight" forever and every deploy would stall until someone deleted
  # the key by hand.
  RAISE_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    local count = redis.call('INCR', KEYS[1])
    redis.call('EXPIRE', KEYS[1], ARGV[1])
    return count
  LUA

  # Lowering the flag: the last job out deletes the key, but if DECR and DEL were two
  # separate calls, a sibling per-type job could INCR in between and have its count
  # deleted — the healthcheck would report "clear" while that sibling was still paying
  # out, letting a deploy land mid-batch. The <= 0 guard also removes any stray negative
  # value so it can't linger and absorb a future batch's increment.
  LOWER_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    local count = redis.call('DECR', KEYS[1])
    if count <= 0 then
      redis.call('DEL', KEYS[1])
    end
    return count
  LUA

  def perform(payout_processor_type, bank_account_types = nil)
    # Fan a multi-bank-type batch out into one job per bank account type. Processing the types
    # sequentially inside a single job meant one slow `holding_balance` query aborted every
    # remaining type's payouts along with it; isolated jobs give each type its own statement
    # budget and its own retries.
    if bank_account_types.is_a?(Array) && bank_account_types.many?
      bank_account_types.each { |bank_account_type| self.class.perform_async(payout_processor_type, [bank_account_type]) }
      Rails.logger.info("AUTOMATED PAYOUTS: #{payout_processor_type} fanned out to #{bank_account_types.size} per-bank-account-type jobs: #{bank_account_types}")
      return
    end

    payout_period_end_date = User::PayoutSchedule.next_scheduled_payout_end_date

    Rails.logger.info("AUTOMATED PAYOUTS: #{payout_period_end_date}, #{payout_processor_type}, #{bank_account_types} (Started)")

    # Mark a payout batch as in flight so the deploy pipeline can hold production
    # deploys only while payouts are actually running (see HealthcheckController#payouts
    # and .buildkite/scripts/deploy_production.sh). A counter (not a boolean) because
    # the multi-bank-type batch fans out to concurrent per-type jobs — the flag must
    # stay up until the LAST one finishes. The TTL is a crash safety net: if a job
    # dies without the ensure running, the flag clears itself instead of freezing
    # deploys forever. 3 hours covers the 2-hour query budget below with headroom.
    # `counted` tracks whether the increment actually landed, so the ensure never
    # decrements a count it didn't add.
    counted = false

    # The database connection defaults to a 5-minute statement cap (config/database.yml).
    # The `holding_balance` eligibility query for a large bank-account-type cohort (US ACH,
    # India, UK) regularly exceeds that cap during the 10:00 UTC batch window, and because
    # all Sidekiq retries land in the same contention window, retries exhaust and every
    # seller in the bucket goes unpaid for the week (4 incidents: #434, #870, #955, and the
    # 2026-07-08 UK batch). Payouts are a weekly batch job, not a user-facing request — a
    # long-running query here is expected, so give it a 2-hour budget instead of letting
    # the default cap kill the batch.
    begin
      $redis.eval(RAISE_IN_FLIGHT_FLAG_SCRIPT, keys: [RedisKey.payout_batch_in_flight], argv: [3.hours.to_i])
      counted = true

      WithMaxExecutionTime.timeout_queries(seconds: 2.hours) do
        if bank_account_types
          Payouts.create_payments_for_balances_up_to_date_for_bank_account_types(payout_period_end_date, payout_processor_type, bank_account_types)
        else
          Payouts.create_payments_for_balances_up_to_date(payout_period_end_date, payout_processor_type)
        end
      end
    ensure
      # Last concurrent per-type job out turns the light off — atomically, so a sibling
      # job's count can never be deleted out from under it (see the script's comment).
      $redis.eval(LOWER_IN_FLIGHT_FLAG_SCRIPT, keys: [RedisKey.payout_batch_in_flight]) if counted
    end

    Rails.logger.info("AUTOMATED PAYOUTS: #{payout_period_end_date}, #{payout_processor_type} #{bank_account_types} (Finished)")
  end
end
