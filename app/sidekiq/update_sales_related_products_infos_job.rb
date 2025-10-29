# frozen_string_literal: true

class UpdateSalesRelatedProductsInfosJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(purchase_id, increment = true)
    return if Feature.inactive?(:update_sales_related_products_infos)

    purchase = Purchase.find(purchase_id)

    product_id = purchase.link_id
    related_product_ids = Purchase
      .successful_or_preorder_authorization_successful_and_not_refunded_or_chargedback
      .where(email: purchase.email)
      .where.not(link_id: product_id)
      .distinct
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
