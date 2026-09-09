# frozen_string_literal: true

class RecoverPendingRefundFeeRetentionJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  # Hourly cron: keep max_attempt under the interval minus RecurringLockTtl::SAFETY_MARGIN
  # so a stranded lock digest cannot mute the next fire.
  include RecurringLockTtl
  recurring_lock_ttl max_attempt: 45.minutes

  def perform
    Refund.pending_fee_retention.find_each do |refund|
      refund.recover_pending_fee_retention!
    rescue StandardError => e
      Rails.logger.error("Pending refund fee retention failed (refund_id=#{refund.id}): #{e.class}: #{e.message}")
      ErrorNotifier.notify(e, context: { refund_id: refund.id, purchase_id: refund.purchase_id })
    end
  end
end
