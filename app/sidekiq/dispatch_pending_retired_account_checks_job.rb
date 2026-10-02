# frozen_string_literal: true

# Backstop for the delayed retired-account check StripeConnectAccountLinker enqueues after a Connect
# switch commits. A Redis failure there leaves the retirement durable and the seller linked, with
# nothing else ever looking at the account again, so the pending check is re-derived from the row.
#
# The marker is written by the linker, so this only ever re-dispatches a retirement the switch made,
# and the check clears it when it runs.
class DispatchPendingRetiredAccountChecksJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  # Room for the check's own schedule to have run first, so a check that is merely queued is not
  # dispatched twice.
  RECOVERY_DELAY = 6.hours

  # A retirement unchecked this long after its tail is left to the payout guard
  # (Payment::FailureReason::DESTINATION_ACCOUNT_RETIRED), which blocks a payout on it in any case.
  LOOKBACK = 7.days

  def perform
    due = AlertOnRetiredManagedAccountActivityJob::SETTLEMENT_TAIL + RECOVERY_DELAY

    MerchantAccount.stripe
                   .where.not(charge_processor_merchant_id: nil)
                   # An absent key and a cleared marker both have to be excluded by value: `->>`
                   # reads a JSON null back as the text 'null', not SQL NULL.
                   .where("COALESCE(json_data->>'$.retired_activity_check_pending_at', '') NOT IN ('', 'null')")
                   .where(deleted_at: LOOKBACK.ago..due.ago)
                   .find_each do |merchant_account|
      AlertOnRetiredManagedAccountActivityJob.perform_async(merchant_account.id, merchant_account.deleted_at.utc.iso8601)
    end
  end
end
