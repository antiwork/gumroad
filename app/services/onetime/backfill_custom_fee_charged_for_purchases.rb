class Onetime::BackfillCustomFeeChargedForPurchases
  def self.run
    Purchase.where(custom_flat_fee_per_thousand_charged: nil).find_in_batches(batch_size: 1000) do |batch|
      batch.each(&:backfill_custom_fee_per_thousand_charged!)
    end
  end
end
