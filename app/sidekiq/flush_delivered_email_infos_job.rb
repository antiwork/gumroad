# frozen_string_literal: true

class FlushDeliveredEmailInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 10.minutes

  def perform
    EmailInfo.flush_delivered_buffer!
  end
end
