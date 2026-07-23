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

  # How long a job's in-flight entry stays valid. This is the crash safety net: if a
  # job dies without its ensure running (or Redis is unreachable during cleanup), the
  # entry stops counting after this long, so a dead job can never freeze deploys
  # forever. 3 hours covers the 2-hour query budget below with headroom. The
  # healthcheck (HealthcheckController#payouts) only counts entries younger than this.
  IN_FLIGHT_ENTRY_TTL = 3.hours

  # Each running payout job registers its own unique token in a Redis sorted set,
  # scored by start time, rather than incrementing a shared counter. A shared counter
  # has an unfixable ambiguity: when Redis executes an increment but the client loses
  # the response (network blip), the job cannot know whether it owns a count — so it
  # must either leak one (stale "in flight" that stalls deploys) or risk decrementing
  # a concurrent sibling job's count (deploy lands mid-batch). With per-job tokens the
  # cleanup is removing our OWN token: idempotent, safe to run no matter how the
  # registration attempt ended, and it can never touch a sibling's entry.
  #
  # ZADD and EXPIRE run as one atomic Lua script so a transient error between them
  # can't leave the key without its expiry backstop.
  RAISE_IN_FLIGHT_FLAG_SCRIPT = <<~LUA
    redis.call('ZADD', KEYS[1], ARGV[1], ARGV[2])
    redis.call('EXPIRE', KEYS[1], ARGV[3])
    return redis.call('ZCARD', KEYS[1])
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
    # and .buildkite/scripts/deploy_production.sh). Each job registers a unique token
    # (a set of tokens, not a boolean) because the multi-bank-type batch fans out to
    # concurrent per-type jobs — the flag must stay up until the LAST one finishes.
    # The per-entry TTL (via the score, enforced by the healthcheck reader) means a
    # crashed job's entry expires on its own instead of freezing deploys forever.
    in_flight_token = "#{Process.pid}-#{SecureRandom.uuid}"

    # The database connection defaults to a 5-minute statement cap (config/database.yml).
    # The `holding_balance` eligibility query for a large bank-account-type cohort (US ACH,
    # India, UK) regularly exceeds that cap during the 10:00 UTC batch window, and because
    # all Sidekiq retries land in the same contention window, retries exhaust and every
    # seller in the bucket goes unpaid for the week (4 incidents: #434, #870, #955, and the
    # 2026-07-08 UK batch). Payouts are a weekly batch job, not a user-facing request — a
    # long-running query here is expected, so give it a 2-hour budget instead of letting
    # the default cap kill the batch.
    begin
      $redis.eval(
        RAISE_IN_FLIGHT_FLAG_SCRIPT,
        keys: [RedisKey.payout_batch_in_flight],
        argv: [Time.current.to_i, in_flight_token, IN_FLIGHT_ENTRY_TTL.to_i]
      )

      WithMaxExecutionTime.timeout_queries(seconds: 2.hours) do
        if bank_account_types
          Payouts.create_payments_for_balances_up_to_date_for_bank_account_types(payout_period_end_date, payout_processor_type, bank_account_types)
        else
          Payouts.create_payments_for_balances_up_to_date(payout_period_end_date, payout_processor_type)
        end
      end
    ensure
      # Remove our own token. This is idempotent (removing an absent member is a no-op)
      # and scoped to this job's entry, so it runs unconditionally: even if the
      # registration above failed — or Redis executed it but the response was lost —
      # cleanup can neither leak our entry nor touch a concurrent sibling job's.
      begin
        $redis.zrem(RedisKey.payout_batch_in_flight, in_flight_token)
      rescue Redis::BaseError => e
        # A failed cleanup self-heals via the entry's TTL; don't let it mask the
        # batch's own outcome (success, or the exception already propagating).
        ErrorNotifier.notify(e, redis_key: RedisKey.payout_batch_in_flight)
      end
    end

    Rails.logger.info("AUTOMATED PAYOUTS: #{payout_period_end_date}, #{payout_processor_type} #{bank_account_types} (Finished)")
  end
end
