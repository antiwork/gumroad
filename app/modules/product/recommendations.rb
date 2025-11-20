# frozen_string_literal: true

module Product::Recommendations
  def recommendable?
    recommendable_reasons.values.all?
  end
  alias_method :recommendable, :recommendable?

  # All of the factors(values/records/etc.) which influence the return value of this method should be watched.
  # Whenever any of those factors change, a `SendToElasticsearchWorker` job must be enqueued to update the `is_recommendable`
  # field in the Elasticsearch index.
  def recommendable_reasons
    reasons = {
      alive: alive?,
      not_archived: !archived?,
      reviews_displayed: display_product_reviews?,
      not_sold_out: max_purchase_count.present? ? sales_count_for_inventory < max_purchase_count : true,
      taxonomy_filled: taxonomy.present?,
      sale_made: sales.counts_towards_volume.exists?,
    }

    user.recommendable_reasons.each do |reason, value|
      reasons[:"user_#{reason}"] = value
    end

    reasons
  end
end
