# frozen_string_literal: true

class DeleteExpiredProductCachedValuesWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  QUERY_BATCH_SIZE = 200
  DELETION_BATCH_SIZE = 100

  # Deletes all rows, except the latest one per product.
  # While still present in the queries for performance, the `expired` status is effectively ignored.
  def perform
    ProductCachedValue.expired.group(:product_id).in_batches(of: QUERY_BATCH_SIZE) do |relation|
      product_ids = relation.select(:product_id).distinct.map(&:product_id)
      kept_max_ids = ProductCachedValue.where(product_id: product_ids).group(:product_id).maximum(:id).values
      loop do
        ReplicaLagWatcher.watch
        rows = ProductCachedValue.expired.where(product_id: product_ids).where.not(id: kept_max_ids).limit(DELETION_BATCH_SIZE)
        deleted_rows = rows.delete_all
        break if deleted_rows < DELETION_BATCH_SIZE
      end
    end
  end
end
