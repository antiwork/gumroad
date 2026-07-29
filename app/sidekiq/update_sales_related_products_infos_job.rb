# frozen_string_literal: true

class UpdateSalesRelatedProductsInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Cap how far one sale fans out. Without a cap, a buyer who owns N products makes a single
  # purchase touch N counter rows and enqueue N+1 cache-refresh jobs, and N is unbounded —
  # that unbounded burst is part of what stalled replication and got this job disabled
  # (gumroad-private#1353 / #1406). We keep the buyer's most recently purchased products
  # because those are the pairings most relevant to "customers also bought" recommendations;
  # the read side only ever consumes a top-N slice anyway (up to 50 inputs, top 10 results,
  # 500 cached relationships per product), so exact counters across an entire purchase
  # history feed precision the read path discards.
  RELATED_PRODUCTS_PER_PURCHASE_LIMIT = 100

  def perform(purchase_id, increment = true)
    return if Feature.inactive?(:update_sales_related_products_infos)

    purchase = Purchase.find(purchase_id)

    product_id = purchase.link_id
    related_product_ids = Purchase
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .where(email: purchase.email)
      .where.not(link_id: product_id)
      # Anchor the slice to this sale. Once the set is capped, "the buyer's most recent 100"
      # is a moving target: a refund runs this job again with increment=false, and by then
      # the buyer may have bought more, so an unanchored query would subtract from pairs the
      # sale never added and leave the pairs it did add counted forever. Cutting the history
      # off at this purchase makes both directions address the same pairs.
      .where(id: ..purchase.id)
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
