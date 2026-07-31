# frozen_string_literal: true

class UpdateSalesRelatedProductsInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Without a limit, one sale touches a counter row and enqueues a cache-refresh job for every
  # product the buyer owns. Most-recent wins because the read path only consumes a top-N slice.
  # Past the limit a reversal recomputes the window and can subtract different pairs than the
  # sale added; don't anchor the window to purchase.id to fix that, it blinds the reversal to
  # purchases refunded in between and breaks the netting for every buyer.
  RELATED_PRODUCTS_PER_PURCHASE_LIMIT = 100

  def perform(purchase_id, increment = true)
    return if Feature.inactive?(:update_sales_related_products_infos)

    purchase = Purchase.find(purchase_id)

    product_id = purchase.link_id
    related_product_ids = Purchase
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .where(email: purchase.email)
      .where.not(link_id: product_id)
      .group(:link_id)
      .order(Purchase.arel_table[:id].maximum.desc)
      .limit(RELATED_PRODUCTS_PER_PURCHASE_LIMIT)
      .pluck(:link_id)

    return if related_product_ids.empty?

    SalesRelatedProductsInfo.update_sales_counts(product_id:, related_product_ids:, increment:)

    base_delay = $redis.get(RedisKey.update_cached_srpis_job_delay_hours)&.to_i || 72
    args = [product_id, *related_product_ids].map { [_1] }
    ats = args.map { base_delay.hours.from_now.to_i + rand(24.hours.to_i) }
    Sidekiq::Client.push_bulk(
      "class" => UpdateCachedSalesRelatedProductsInfosJob,
      "args" => args,
      "queue" => "low",
      "at" => ats,
    )
  end
end
