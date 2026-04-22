# frozen_string_literal: true

class Onetime::BackfillLicenseUsesForSeller
  BATCH_SIZE = 1_000

  attr_reader :seller

  def initialize(seller:)
    @seller = seller
  end

  def process
    License
      .joins(:purchase)
      .where(purchases: { seller_id: seller.id, purchase_state: Purchase::NON_GIFT_SUCCESS_STATES })
      .where.not(purchase_id: nil)
      .in_batches(of: BATCH_SIZE) do |relation|
        ReplicaLagWatcher.watch

        purchase_ids = relation.pluck(Arel.sql("licenses.purchase_id"))
        jobs = purchase_ids.map do |purchase_id|
          ["update", { "record_id" => purchase_id, "class_name" => "Purchase", "fields" => ["license_uses"] }]
        end
        ElasticsearchIndexerWorker.perform_bulk(jobs) if jobs.any?
      end
  end
end
