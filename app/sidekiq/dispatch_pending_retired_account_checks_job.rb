# frozen_string_literal: true

# Backstop for the delayed retired-account check StripeConnectAccountLinker enqueues after a Connect
# switch commits: a lost enqueue leaves the marker set with nothing else reading it. Only the linker
# writes the marker, so this cannot re-dispatch a retirement the switch did not make.
class DispatchPendingRetiredAccountChecksJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  # Room for the check's own schedule to have run first, so a check that is merely queued is not
  # dispatched twice.
  RECOVERY_DELAY = 6.hours

  def perform
    due = AlertOnRetiredManagedAccountActivityJob::SETTLEMENT_TAIL + RECOVERY_DELAY

    MerchantAccount.stripe
                   .where.not(charge_processor_merchant_id: nil)
                   # An absent key and a cleared marker both have to be excluded by value: `->>`
                   # reads a JSON null back as the text 'null', not SQL NULL.
                   .where("COALESCE(json_data->>'$.retired_activity_check_pending_at', '') NOT IN ('', 'null')")
                   # The marker is cleared when the check runs, so no age window: an old marker is
                   # exactly the lost check, and the upper edge alone keeps a check whose own
                   # schedule has not fired yet from being dispatched twice.
                   .where(deleted_at: ..due.ago)
                   .find_each do |merchant_account|
      AlertOnRetiredManagedAccountActivityJob.perform_async(merchant_account.id, merchant_account.deleted_at.utc.iso8601)
    end
  end
end
