# frozen_string_literal: true

# Seller-level rating rollup over per-product review stats. Everything here is
# gated on the :seller_reputation_summary Flipper via reputation_summary_enabled?.
#
# Performance (gumroad-private#2384): the old read materialised every matching
# ProductReviewStat + Link row into Ruby on every product/profile request and
# iterated them, so an enumerating crawl over an 11k-product catalogue saturated
# the DB master. The rollup is now computed once per seller per version bump as
# a single SQL aggregate (bounded memory, one row back), then served from the
# shared Rails cache. The per-seller version is bumped by the review-stat write
# funnel (the only code that changes a product's review counters), so a product
# /profile view is an O(1) cache read, and exclude_product subtracts one product's
# stored stat rather than re-scanning the catalogue.
module User::ReputationSummary
  # Below these the rollup reads as noise, not signal (gumroad-private#1669).
  # Product-owned numbers: change them in one line, not by redesign.
  MIN_REVIEWS = 10
  MIN_PRODUCTS = 2

  CACHE_PREFIX = "seller_reputation_summary"
  # Schema/bucketing rev; bump if the cached aggregate's shape changes.
  CACHE_VERSION = "v2"
  # Rails.cache is a shared memcached. The rollup only changes when a review
  # stat write lands, but we also serve it with a short absolute TTL so a
  # funnel bump that is lost to a network partition cannot pin a stale rollup
  # forever.
  CACHE_TTL = 10.minutes

  # Bump the seller's rollup version. Product::ReviewStat calls this (via the
  # link) after a review rank changed — it is the ONE writer of a product's
  # review stats, so bumping here keeps every seller rollup honest while
  # staying cheap (a Redis INCR, no DB scan). No-op when the flag is off or
  # the seller is unknown.
  def bump_reputation_summary_version
    return unless reputation_summary_enabled?

    $redis.incr(reputation_version_key)
    $redis.expire(reputation_version_key, CACHE_TTL + 60)
  end

  def reputation_summary_enabled?
    Feature.active?(:seller_reputation_summary, self)
  end

  # Cheap (Redis GET) per-seller version bumped by the review-stat write funnel
  # (bump_reputation_summary_version). Read by Pages::ProfileData so its cache
  # key moves on a review write WITHOUT a scan of the review-stat join — the
  # old signature recomputed the full SUM on every cache lookup (gp#2384).
  def reputation_summary_cache_signature
    $redis.get(reputation_version_key).to_i
  end

  # Returns { average:, count:, products_count: } or nil when the seller does
  # not meet the display gate. exclude_product keeps a product page's rollup
  # from silently counting that product's own reviews.
  def seller_reputation_summary(exclude_product: nil)
    return nil unless reputation_summary_enabled?

    aggregate = reputation_aggregate
    aggregate = subtract_product(aggregate, exclude_product) if exclude_product
    build_summary(aggregate)
  end

  private
    # One-row SQL aggregate over the seller's eligible, non-zero-review
    # products — bounded regardless of catalogue size (gumroad-private#2384).
    # display_product_reviews is a Link flag bit, not a column, so it is
    # meshed here exactly the way ProfileData already does (links.flags & BIT).
    def reputation_aggregate
      Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
        products_count, total, weighted = ProductReviewStat.joins(:link)
          .merge(Link.alive.not_draft)
          .where(links: { user_id: id })
          .where.not("product_review_stats.reviews_count" => 0)
          .where(Arel.sql("links.flags & #{Link.flag_mapping["flags"][:display_product_reviews]} != 0"))
          .pick(Arel.sql("COUNT(*), SUM(reviews_count), SUM(ratings_of_five_count * 5 + ratings_of_four_count * 4 + ratings_of_three_count * 3 + ratings_of_two_count * 2 + ratings_of_one_count)"))
        [products_count.to_i, total.to_i, weighted.to_i]
      end
    end

    # Cache key: seller + a products lifecycle version (moves when a product is
    # drafted/deleted/flag-flipped, i.e. links.updated_at changes) + the funnel
    # version (moves on review-stat writes, which touch product_review_stats,
    # not links). Both are cheap reads; neither scans the review-stat join.
    def cache_key
      lifecycle = products.cache_key_with_version
      version = $redis.get(reputation_version_key).to_i
      "#{CACHE_PREFIX}/#{CACHE_VERSION}/#{id}/#{lifecycle}/#{version}"
    end

    def reputation_version_key
      "#{CACHE_PREFIX}/version/#{id}"
    end

    # aggregate is [products_count, total_reviews, weighted_sum]. Drop a
    # product only if it actually factored into the aggregate (mirror the SQL
    # floor), so product X leaving its page never eats another product's
    # reviews.
    def subtract_product(aggregate, product)
      return aggregate unless aggregate && product

      stat = ProductReviewStat.find_by(link_id: product.id)
      return aggregate if stat.nil? || stat.reviews_count.zero? || !product.display_product_reviews? || !product.alive? || product.draft?

      products, total, weighted = aggregate
      weighted -= stat.rating_counts.sum { |rating, rating_count| rating * rating_count.to_i }
      [products - 1, total - stat.reviews_count, weighted]
    end

    def build_summary(aggregate)
      products, total, weighted = aggregate
      return nil if total < MIN_REVIEWS || products < MIN_PRODUCTS

      {
        average: (weighted.to_f / total).round(1),
        count: total,
        products_count: products,
      }
    end
end
