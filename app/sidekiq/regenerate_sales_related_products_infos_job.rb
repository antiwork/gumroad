# frozen_string_literal: true

# WARNING: This job can be very slow, and add a lot of rows to the DB.
# It is only meant for rare cases, for example: improving quality of recommendations for a VIP creator's product.
# It should NOT be run for more than a few of products at time.
class RegenerateSalesRelatedProductsInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(product_id, email_limit = 5_000, relationships_limit = 1_000, insert_batch_size = 10)
    product = Link.find(product_id)

    emails = Purchase
      .distinct
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .where(link_id: product_id)
      .where.not(email: nil)
      .limit(email_limit)
      .order(id: :desc)
      .pluck(:email)

    customer_counts = Purchase
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .where(email: emails)
      .where.not(link_id: product_id)
      .select(:link_id, "COUNT(DISTINCT(email)) as customer_count")
      .group(:link_id)
      .order(customer_count: :desc)
      .limit(relationships_limit)
      .to_a

    SalesRelatedProductsInfo.for_product_id(product.id).in_batches.delete_all

    now_string = %("#{Time.current.to_fs(:db)}")
    inserts = customer_counts.map do |record|
      smaller_id, larger_id = [product_id, record.link_id].sort
      [smaller_id, larger_id, record.customer_count, now_string, now_string].join(", ")
    end.map { "(#{_1})" }

    # Small slices to avoid deadlocks.
    inserts.each_slice(insert_batch_size) do |inserts_slice|
      inserts_sql_slice = inserts_slice.join(", ")
      query = <<~SQL
        INSERT IGNORE INTO #{SalesRelatedProductsInfo.table_name}
        (smaller_product_id, larger_product_id, sales_count, created_at, updated_at)
        VALUES
        #{inserts_sql_slice};
      SQL
      ApplicationRecord.connection.execute(query)
    end
  end
end
