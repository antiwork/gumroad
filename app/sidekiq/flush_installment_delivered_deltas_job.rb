# frozen_string_literal: true

class FlushInstallmentDeliveredDeltasJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  def perform
    Installment.flush_delivered_deltas!
  end
end
