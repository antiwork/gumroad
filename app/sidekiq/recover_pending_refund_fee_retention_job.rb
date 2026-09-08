# frozen_string_literal: true

class RecoverPendingRefundFeeRetentionJob
  include Sidekiq::Job

  sidekiq_options retry: 5, queue: :low, lock: :until_executed

  def perform
    Refund.pending_fee_retention.find_each(&:recover_pending_fee_retention!)
  end
end
