# frozen_string_literal: true

# Catches a product that is "selling" far more than anyone is looking at it.
#
# Every checkout on a free product sends the buyer a receipt from our transactional
# sending domain, so a script that walks a scraped address list through checkout turns
# our receipt mailer into a bulk mailer with our branding on it. That happened over four
# days in July 2026: one free product took ~230,000 checkouts to ~148,000 distinct
# addresses while its product page was viewed 10,568 times. Nobody was visiting the page,
# because nobody was buying — a script was posting the checkout directly.
#
# That shape is what this detector looks for: within a short window, a free product with a
# high number of sales AND far more sales than page views. Real products are the other way
# round — a few percent of the people who look at a page buy. Sales exceeding views by a
# wide margin means the traffic never came through the page at all.
#
# When it fires it does two things, in this order:
#
#   1. Unpublishes the product, which is what actually stops an in-flight blast. Suspending
#      the seller does not: in the July incident 800 more receipts went out in the ten
#      minutes after the ban, because checkout stays open on a live product.
#   2. Flags the seller for a policy violation so the account lands in the admin review
#      queue with the numbers recorded on it.
#
# Flag, not suspend, is deliberate. Detection needs no human; releasing does. An admin
# reviews the flagged account and either suspends it or marks it compliant and republishes.
class AutoFlagInvertedSalesToViews
  # How far back each run looks. The job runs hourly, so the window matches the cadence.
  WINDOW = 1.hour

  # A product needs at least this many free sales inside the window before the ratio is
  # even considered. Without it, a brand-new product with 3 sales and 0 recorded views
  # (page views are indexed asynchronously, so they can lag) would look "inverted".
  MIN_FREE_SALES_IN_WINDOW = 500

  # How many times sales have to exceed views to count as inverted. A legitimate product
  # can show more sales than views in small numbers — a buyer arriving from an embed, a
  # bundle, or a link that skips the product page — so requiring sales to be several times
  # views leaves room for that. The July incident ran at roughly 22x.
  INVERSION_MULTIPLIER = 5

  FLAG_AUTHOR_NAME = "auto_flag_inverted_sales_to_views"
  TOS_VIOLATION_REASON = "Automated checkout abuse: sales far exceeding product page views"

  # Kill switch. Flipper features are off unless enabled, so this is phrased as a disable
  # so the detector is on by default and can be turned off without a deploy.
  KILL_SWITCH_FEATURE = :disable_auto_flag_inverted_sales_to_views

  def initialize(window: WINDOW)
    @window_ends_at = Time.current
    @window_starts_at = @window_ends_at - window
  end

  def process
    return [] if Feature.active?(KILL_SWITCH_FEATURE)

    sales_by_product_id = free_sales_by_product_id
    return [] if sales_by_product_id.empty?

    views_by_product_id = views_by_product_id_for(sales_by_product_id.keys)

    sales_by_product_id.filter_map do |product_id, sales_count|
      views_count = views_by_product_id[product_id].to_i
      next unless inverted?(sales_count:, views_count:)

      product = Link.find_by(id: product_id)
      next if product.nil?
      next unless actionable?(product)

      act_on(product:, sales_count:, views_count:)
      product_id
    end
  end

  private
    attr_reader :window_starts_at, :window_ends_at

    def inverted?(sales_count:, views_count:)
      sales_count >= MIN_FREE_SALES_IN_WINDOW && sales_count > views_count * INVERSION_MULTIPLIER
    end

    # Free sales only. A paid product outselling its page views is usually a seller mailing
    # a direct checkout link to their own list, which is legitimate and costs us nothing.
    # The abuse this detector exists for is specifically free checkouts, because those are
    # the ones that mail an arbitrary unverified address for free.
    def free_sales_by_product_id
      Purchase.successful
              .where(price_cents: 0)
              .where(created_at: window_starts_at..window_ends_at)
              .group(:link_id)
              .having("COUNT(*) >= ?", MIN_FREE_SALES_IN_WINDOW)
              .count
    end

    # One Elasticsearch call for every candidate product rather than one per product.
    # Products with no views in the window simply don't come back as buckets, and the
    # caller reads a missing bucket as zero.
    def views_by_product_id_for(product_ids)
      return {} if product_ids.empty?

      response = EsClient.search(
        index: ProductPageView.index_name,
        body: {
          size: 0,
          query: {
            bool: {
              filter: [
                { terms: { product_id: product_ids } },
                { range: { timestamp: { gte: window_starts_at.iso8601, lte: window_ends_at.iso8601 } } }
              ]
            }
          },
          aggs: {
            views_by_product: {
              terms: { field: "product_id", size: product_ids.size }
            }
          }
        }
      )

      buckets = response.dig("aggregations", "views_by_product", "buckets") || []
      buckets.each_with_object({}) do |bucket, result|
        result[bucket["key"].to_i] = bucket["doc_count"]
      end
    end

    def actionable?(product)
      return false unless product.alive?

      seller = product.user
      return false if seller.nil?
      # Team accounts run internal test products; suspending our own storefront on a
      # traffic spike would be worse than the thing we're preventing.
      return false if seller.is_team_member?
      return false if seller.suspended?

      true
    end

    def act_on(product:, sales_count:, views_count:)
      content = comment_content(product:, sales_count:, views_count:)

      ActiveRecord::Base.transaction do
        # Unpublish first. This is the part that stops sends; the flag is bookkeeping.
        product.unpublish!(is_unpublished_by_admin: true)

        seller = product.user
        if seller.can_flag_for_tos_violation?
          seller.update!(tos_violation_reason: TOS_VIOLATION_REASON)
          seller.flag_for_tos_violation!(author_name: FLAG_AUTHOR_NAME, product_id: product.id, content:)
        else
          # The seller is already flagged or on probation, so the state machine won't take
          # another flag transition. Record what happened on the product anyway, otherwise
          # an admin reviewing it sees an unpublished product with no explanation.
          product.comments.create!(
            author_name: FLAG_AUTHOR_NAME,
            comment_type: Comment::COMMENT_TYPE_FLAG_NOTE,
            content:
          )
        end
      end

      AdminMailer.inverted_sales_to_views_notify(product.id, sales_count, views_count).deliver_later(queue: "default")
    end

    def comment_content(product:, sales_count:, views_count:)
      "Product '#{product.name}' unpublished automatically on #{Time.current.to_fs(:formatted_date_full_month)}: " \
        "#{ActiveSupport::NumberHelper.number_to_delimited(sales_count)} free sales against " \
        "#{ActiveSupport::NumberHelper.number_to_delimited(views_count)} product page views in the previous hour. " \
        "Sales far exceeding views means the checkouts did not come through the product page, " \
        "which is the signature of scripted checkouts using the receipt email as a mailer."
    end
end
