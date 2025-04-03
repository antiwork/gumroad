# frozen_string_literal: true

module Product::ReviewStat
  delegate :average_rating, :rating_counts, :reviews_count, :rating_percentages, to: :review_stat_proxy

  def rating_stats
    {
      count: reviews_count,
      average: average_rating,
      percentages: rating_percentages.values,
    }
  end

  def update_review_stat_via_rating_change(old_rating, new_rating)
    create_product_review_stat if product_review_stat.nil?
    if old_rating.nil?
      product_review_stat.update_with_added_rating(new_rating)
    elsif new_rating.nil?
      product_review_stat.update_with_removed_rating(old_rating)
    else
      product_review_stat.update_with_changed_rating(old_rating, new_rating)
    end
    enqueue_index_update_for_reviews
  end

  def update_review_stat_via_purchase_changes(purchase_changes, product_review:)
    return if product_review.nil? || purchase_changes.blank?
    purchase = product_review.purchase
    purchase_is_valid = purchase.allows_review_to_be_counted?
    old_purchase = Purchase.new(
      purchase.attributes
        .except(*Purchase.unused_attributes)
        .merge(purchase_changes.stringify_keys.transform_values(&:first))
    )
    old_purchase_is_valid = old_purchase.allows_review_to_be_counted?
    if old_purchase_is_valid && !purchase_is_valid
      product_review_stat.update_with_removed_rating(product_review.rating)
      product_review.mark_deleted! unless product_review.deleted?
      enqueue_index_update_for_reviews
    elsif !old_purchase_is_valid && purchase_is_valid && product_review_stat.present?
      product_review_stat.update_with_added_rating(product_review.rating)
      product_review.mark_undeleted! unless product_review.alive?
      enqueue_index_update_for_reviews
    end
  end

  # Admin methods. VERY slow for large sellers, so only use if necessary.
  # For example, avoid: `Link.find_each(&:sync_review_stat)`
  def sync_review_stat
    data = generate_review_stat_attributes
    if product_review_stat.nil? && data[:reviews_count] > 0
      create_product_review_stat(data)
    elsif !product_review_stat.nil?
      product_review_stat.update!(data)
    end
  end

  def generate_review_stat_attributes
    data = { link_id: id }
    valid_purchases = sales.allowing_reviews_to_be_counted
    valid_reviews = product_reviews.joins(:purchase).merge(valid_purchases)
    rating_counts = valid_reviews.group(:rating).count
    reviews_count = rating_counts.values.sum
    data[:reviews_count] = reviews_count
    if reviews_count > 0
      average_rating = (rating_counts.map { |rating, rating_count| rating * rating_count }.sum.to_f / reviews_count).round(1)
    else
      average_rating = 0
    end
    data[:average_rating] = average_rating
    ProductReviewStat::RATING_COLUMN_MAP.each do |rating, column_name|
      data[column_name] = rating_counts[rating] || 0
    end
    data
  end
  # /Admin methods.

  private
    def review_stat_proxy
      product_review_stat || ProductReviewStat::TEMPLATE
    end

    def enqueue_index_update_for_reviews
      enqueue_index_update_for(%w(average_rating reviews_count is_recommendable))
    end
end
