# frozen_string_literal: true

# Flags a seller for risk review when their live listing prices line up with a watched
# set of price points.
#
# Transaction-laundering operators sell an off-platform service (for example an IPTV
# subscription) through stand-in listings priced at that service's plan prices. When one
# of their accounts is suspended they come back on another account with the same prices,
# so a seller whose catalog reproduces several of those prices is worth a human look
# before the sales pile up.
#
# The watched sets live in Redis, not in code, so the prices of a live investigation are
# never published and risk can add or retire a set without a deploy:
#
#   $redis.set(RedisKey.watched_price_point_sets, "1000,2000,3000;4500,9000,13500")
#
# Sets are separated by ";" and prices (in cents) by ",". With no sets configured the job
# does nothing.
#
# The job only flags (flagged_for_fraud, the state the review queue reads); it never
# suspends, refunds or pauses payouts. A seller is flagged by this job at most once, so a
# human who reviews and clears them is not overruled by the next price edit.
class CheckWatchedPricePointsJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  AUTHOR_NAME = "WatchedPricePoints"
  MIN_MATCHING_PRICE_POINTS = 3
  ENQUEUE_DELAY = 2.minutes

  def self.watched_sets
    raw = $redis.get(RedisKey.watched_price_point_sets).to_s
    raw.split(";").filter_map do |set|
      prices = set.split(",").filter_map { |price| Integer(price.strip, exception: false) }.select(&:positive?).uniq
      prices if prices.size >= MIN_MATCHING_PRICE_POINTS
    end
  end

  def self.enqueue_for(seller_id)
    return if seller_id.blank? || watched_sets.empty?

    perform_in(ENQUEUE_DELAY, seller_id)
  end

  def perform(seller_id)
    sets = self.class.watched_sets
    return if sets.empty?

    seller = User.find_by(id: seller_id)
    return if seller.nil? || seller.verified? || !seller.can_flag_for_fraud?
    return if already_flagged_by_this_job?(seller)

    seller_prices = live_price_points(seller)
    best_match = sets.map { |set| set & seller_prices }.max_by(&:size)
    return if best_match.size < MIN_MATCHING_PRICE_POINTS

    flag!(seller, best_match.sort)
  end

  private
    def already_flagged_by_this_job?(seller)
      seller.comments.where(author_name: AUTHOR_NAME).exists?
    end

    # Every price a buyer can pay on the seller's live listings: each product's price, each
    # live Price row (recurrences, rentals), and the product price plus each live variant's
    # price difference.
    def live_price_points(seller)
      products = seller.links.alive.to_a
      product_prices = products.to_h { |product| [product.id, product.price_cents.to_i] }

      price_rows = Price.alive.where(link_id: product_prices.keys).pluck(:price_cents)

      variant_prices = Variant.alive
        .joins(:variant_category)
        .merge(VariantCategory.alive)
        .where(variant_categories: { link_id: product_prices.keys })
        .pluck("variant_categories.link_id", :price_difference_cents)
        .map { |link_id, difference| product_prices[link_id].to_i + difference.to_i }

      (product_prices.values + price_rows + variant_prices).compact.select(&:positive?).uniq
    end

    def flag!(seller, matched_prices)
      seller.with_lock do
        seller.reload
        next if seller.verified? || !seller.can_flag_for_fraud?
        next if already_flagged_by_this_job?(seller)

        seller.comments.create!(
          author_name: AUTHOR_NAME,
          comment_type: Comment::COMMENT_TYPE_FLAG_NOTE,
          content: "Live listing prices match #{matched_prices.size} prices of a watched price-point set " \
                   "(#{matched_prices.map { |cents| format("%.2f", cents / 100.0) }.join(", ")}). " \
                   "Check for transaction laundering or ban evasion before clearing."
        )
        seller.flag_for_fraud!(author_name: AUTHOR_NAME)
      end
    end
end
