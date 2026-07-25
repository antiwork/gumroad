# frozen_string_literal: true

# Evaluates payout eligibility for one bounded slice of sellers and enqueues that slice's
# payouts.
#
# The weekly batch used to do this inline: one orchestrator job walked the entire
# holding-balance cohort (~195k sellers) itself, running several queries per seller. On
# Fridays (PayPal and Stripe Connect, no bank-account-type filter) that walk took about two
# hours, which is longer than a Sidekiq worker's lifetime in production — so the job was
# killed, sidekiq-pro's orphan recovery restarted it from the first seller, and after enough
# restarts it was buried in the dead set with most of the cohort unpaid
# (gumroad-private#1021 on 2026-07-10, again #1284 on 2026-07-24).
#
# Splitting the per-seller work into its own job per slice means the orchestrator only has to
# read seller ids (a few minutes at most) and progress is durable: a worker recycle costs one
# slice, the rest keep going, and Sidekiq retries just that slice. Re-running a slice is safe
# because Payouts.create_payment no-ops once a seller's balances have left the `unpaid` state.
class PerformPayoutsForUserSliceWorker
  include Sidekiq::Job
  include HoldsDeployWhileRunning

  # Slices are independent, so a transient failure (statement timeout, PayPal blip) should
  # retry this slice rather than leaving its sellers unpaid for the week.
  #
  # These run on :default rather than :critical, matching PayoutUsersWorker (the per-seller
  # payout job this one enqueues). Several slices run at once, each holding a thread for
  # roughly half a minute of eligibility queries, and :critical is where purchase receipts
  # and other buyer-facing work live — a slow payout Friday must not be able to delay a
  # buyer's receipt. Nothing here is latency-sensitive: the batch has a multi-hour window.
  sidekiq_options retry: 3, queue: :default

  # A slice is USER_LOOKUP_BATCH_SIZE sellers, so it needs far less than the whole batch's
  # budget — but it still runs several queries per seller inside the contended batch window,
  # which is well past the 5-minute default statement cap in config/database.yml.
  QUERY_TIME_BUDGET = 30.minutes

  sidekiq_retries_exhausted do |job, exception|
    payout_processor_type, _date_string, user_ids, bank_account_type = job["args"]
    # A slice-specific alert, not the whole-batch one: only this slice's sellers are unpaid,
    # and the fix is to retry this dead job rather than re-run the entire processor bucket.
    AccountingMailer.payout_batch_slice_failed(payout_processor_type, bank_account_type, user_ids&.size, exception.class.name, exception.message).deliver_later
    ErrorNotifier.notify(exception, payout_processor_type:, bank_account_type:, user_ids_count: user_ids&.size)
  end

  def perform(payout_processor_type, date_string, user_ids, bank_account_type = nil)
    return if user_ids.blank?

    payout_period_end_date = Date.parse(date_string)

    while_holding_deploys do
      WithMaxExecutionTime.timeout_queries(seconds: QUERY_TIME_BUDGET) do
        Payouts.create_payments_for_balances_up_to_date_for_user_ids(
          payout_period_end_date,
          payout_processor_type,
          user_ids,
          bank_account_type:
        )
      end
    end
  end
end
