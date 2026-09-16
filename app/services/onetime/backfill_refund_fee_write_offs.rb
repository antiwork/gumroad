# frozen_string_literal: true

class Onetime::BackfillRefundFeeWriteOffs
  # Pre-deploy capped rows are no longer selected by the hourly recovery job.
  def self.process
    Refund.where(fee_retention_recoverable: false)
      .where("refunds.json_data->>'$.fee_retention_pending' = 'true'")
      .where("CAST(refunds.json_data->>'$.fee_retention_attempts' AS UNSIGNED) >= ?", Refund::MAX_FEE_RETENTION_ATTEMPTS)
      .find_each do |refund|
        ReplicaLagWatcher.watch
        refund.write_off_fee_retention!
      end
  end
end
