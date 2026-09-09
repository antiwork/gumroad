# frozen_string_literal: true

class RecoverPendingRefundFeeRetentionJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  # Hourly cron. Worst case is one Stripe collection per pending row; keep the
  # declared attempt under interval − RecurringLockTtl::SAFETY_MARGIN so a
  # stranded digest cannot mute the next fire. Unindexed pending_fee_retention
  # remains a separate queue-schema issue.
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
