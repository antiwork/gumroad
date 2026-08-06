# frozen_string_literal: true

# Seller-level rating rollup over per-product review stats, computed on read:
# sum the per-star counters, weight by review count. Everything here is gated on
# the :seller_reputation_summary Flipper flag via reputation_summary_enabled?.
module User::ReputationSummary
  # Below these the rollup reads as noise, not signal (gumroad-private#1669).
  # Product-owned numbers: change them in one line, not by redesign.
  MIN_REVIEWS = 10
  MIN_PRODUCTS = 2

  def reputation_summary_enabled?
    Feature.active?(:seller_reputation_summary, self)
  end

  # Returns { average:, count:, products_count: } or nil when the seller does
  # not meet the display gate. exclude_product keeps a product page's rollup
  # from silently counting that product's own reviews.
  def seller_reputation_summary(exclude_product: nil)
    return nil unless reputation_summary_enabled?

    counts = Hash.new(0)
    products_count = 0
    # display_product_reviews is a Link flag bit, not a column, so opted-out
    # products are rejected in Ruby rather than in SQL. Link.alive alone
    # does not exclude drafts, hence not_draft.
    stats = ProductReviewStat.joins(:link)
      .merge(Link.alive.not_draft)
      .where(links: { user_id: id })
      .where.not(reviews_count: 0)
      .preload(:link)
    stats.each do |stat|
      next if exclude_product && stat.link_id == exclude_product.id
      next unless stat.link.display_product_reviews?

      products_count += 1
      stat.rating_counts.each { |rating, count| counts[rating] += count.to_i }
    end

    total = counts.values.sum
    return nil if total < MIN_REVIEWS || products_count < MIN_PRODUCTS

    {
      average: (counts.sum { |rating, count| rating * count }.to_f / total).round(1),
      count: total,
      products_count:,
    }
  end
end
