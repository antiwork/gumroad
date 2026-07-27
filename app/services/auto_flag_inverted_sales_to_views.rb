# frozen_string_literal: true

# Catches a product that is "selling" far more than anyone is looking at it, from far fewer
# clients than it has buyers.
#
# Every checkout on a free product sends the buyer a receipt from our transactional sending
# domain, so a script that walks a scraped address list through checkout turns our receipt
# mailer into a bulk mailer with our branding on it. That happened over four days in July
# 2026: one free product took ~230,000 checkouts to ~148,000 distinct addresses while its
# product page was viewed 10,568 times, from 16,933 IP addresses. Nobody was visiting the
# page, because nobody was buying — a script was posting the checkout directly.
#
# Two signals, both required, because either one alone describes legitimate selling too:
#
#   1. Sales far exceeding page views. Real products sell to a fraction of the people who
#      look at the page. But on its own this also describes a seller mailing a direct
#      checkout link to their list: `/l/<permalink>?wanted=true` redirects straight to
#      checkout without ever rendering the product page, so a lead magnet blasted to a big
#      newsletter records thousands of sales and almost no views. That is the promoted way
#      to deliver a free lead magnet, and by ratio alone it is indistinguishable from abuse.
#
#   2. Far fewer distinct browser clients than sales. This is what separates the two. Real
#      buyers each arrive in their own browser, so a legitimate blast to 5,000 people comes
#      from roughly 5,000 distinct `browser_guid` cookies. A script posting checkouts reuses
#      a handful of clients, or sends no cookie at all. The July operator rotated proxies but
#      not browsers.
#
# When both fire it does two things, in this order:
#
#   1. Unpublishes the product, which is what actually stops an in-flight blast. Suspending
#      the seller does not: in the July incident 800 more receipts went out in the ten
#      minutes after the ban, because checkout stays open on a live product.
#   2. Records the counts as a note on the product and emails risk, so a human can decide
#      what, if anything, should happen to the account.
#
# It deliberately does NOT touch the seller's risk state. The signal it reads — free
# checkouts on a public product — is one that anybody on the internet can generate, so a
# script pointed at somebody else's free product produces exactly the same rows as a seller
# abusing their own. Taking the product down is safe under both readings and reversible in
# one click: either way the receipts stop going out under our sending domain, which is the
# harm being prevented. Deciding that the SELLER did it is not safe under both readings, so
# that judgement stays with the admin who reads the email. Detection needs no human;
# attributing blame does.
class AutoFlagInvertedSalesToViews
  # How far back each run looks. The job runs hourly, so the window matches the cadence.
  WINDOW = 1.hour

  # A product needs at least this many free sales inside the window before anything is
  # considered. Without it, a brand-new product with 3 sales and 0 recorded views (page views
  # are indexed asynchronously, so they can lag) would look "inverted".
  MIN_FREE_SALES_IN_WINDOW = 500

  # How many times sales have to exceed views to count as inverted. A legitimate product can
  # show more sales than views in small numbers — a buyer arriving from an embed, a bundle, or
  # a link that skips the product page — so requiring sales to be several times views leaves
  # room for that. The July incident ran at roughly 22x.
  INVERSION_MULTIPLIER = 5

  # How many sales one distinct browser client has to account for before the traffic looks
  # scripted. Real buyers are one client each, so this sits at 1 for legitimate selling no
  # matter how large the launch; five is far above the noise from shared computers and repeat
  # buyers, and far below what a script produces.
  #
  # Counted on `browser_guid`, the per-browser cookie. `COUNT(DISTINCT ...)` skips NULLs, so a
  # script sending no cookie at all lands at zero distinct clients and trips this immediately,
  # which is the correct read.
  MIN_SALES_PER_DISTINCT_CLIENT = 5

  # A single incident is one product, occasionally a handful. If a whole run trips, the far
  # more likely explanation is that the views side broke — an Elasticsearch indexing backlog
  # makes the search succeed and return zero views for everything, which would read as every
  # busy free product on the platform inverting at once. Rather than mass-unpublish on a bad
  # read, the run takes no action and tells risk to look.
  MAX_PRODUCTS_PER_RUN = 5

  # Recorded as the author of the note left on the product, so an admin reading the product
  # can tell the takedown came from this detector rather than from a person.
  NOTE_AUTHOR_NAME = "auto_flag_inverted_sales_to_views"

  # Kill switch. Flipper features are off unless enabled, so this is phrased as a disable so
  # the detector is on by default and can be turned off without a deploy.
  KILL_SWITCH_FEATURE = :disable_auto_flag_inverted_sales_to_views

  Candidate = Struct.new(:product_id, :sales_count, :distinct_clients, :views_count, keyword_init: true)

  def initialize(window: WINDOW)
    # Anchored to the top of the hour rather than to "now" so consecutive runs tile exactly.
    # A run delayed by queue latency would otherwise leave a gap of sales nothing looks at.
    @window_ends_at = Time.current.beginning_of_hour
    @window_starts_at = @window_ends_at - window
  end

  def process
    return [] if Feature.active?(KILL_SWITCH_FEATURE)

    candidates = candidates_with_views
    return [] if candidates.empty?

    flagworthy = candidates.select { flagworthy?(_1) }
    return [] if flagworthy.empty?

    if flagworthy.size > MAX_PRODUCTS_PER_RUN
      report_suspected_systemic_failure(flagworthy)
      return []
    end

    flagworthy.filter_map do |candidate|
      product = Link.find_by(id: candidate.product_id)
      next if product.nil?
      next unless actionable?(product)

      act_on(product:, candidate:)
      candidate.product_id
    rescue => e
      # One product's failure must not abort the rest of the sweep. The product may already be
      # unpublished by this point, which is the outcome that matters.
      ErrorNotifier.notify(e, context: { product_id: candidate.product_id, source: NOTE_AUTHOR_NAME })
      nil
    end
  end

  private
    attr_reader :window_starts_at, :window_ends_at

    def flagworthy?(candidate)
      candidate.sales_count > candidate.views_count * INVERSION_MULTIPLIER &&
        candidate.sales_count > candidate.distinct_clients * MIN_SALES_PER_DISTINCT_CLIENT
    end

    def candidates_with_views
      sales = free_sales_by_product_id
      return [] if sales.empty?

      views = views_by_product_id_for(sales.keys)

      sales.map do |product_id, (sales_count, distinct_clients)|
        Candidate.new(product_id:, sales_count:, distinct_clients:, views_count: views[product_id].to_i)
      end
    end

    # Free sales only. A paid product outselling its page views is usually a seller mailing a
    # direct checkout link to their own list, which is legitimate and costs us nothing. The
    # abuse this detector exists for is specifically free checkouts, because those are the ones
    # that mail an arbitrary unverified address for free.
    #
    # Bundle child purchases are excluded. Buying a bundle creates a separate $0 purchase row
    # for every product inside it (see Purchase::CreateBundleProductPurchaseService), and the
    # buyer only ever visits the bundle's page — so a bundle selling well would otherwise read
    # as every product inside it taking hundreds of "free sales" against zero views.
    def free_sales_by_product_id
      Purchase.successful
              .not_is_bundle_product_purchase
              .where(price_cents: 0)
              .where(created_at: window_starts_at...window_ends_at)
              .group(:link_id)
              .having("COUNT(*) >= ?", MIN_FREE_SALES_IN_WINDOW)
              .pluck(Arel.sql("purchases.link_id, COUNT(*), COUNT(DISTINCT purchases.browser_guid)"))
              .each_with_object({}) { |(link_id, count, clients), result| result[link_id] = [count, clients] }
    end

    # One Elasticsearch call for every candidate product rather than one per product. Products
    # with no views in the window simply don't come back as buckets, and the caller reads a
    # missing bucket as zero.
    def views_by_product_id_for(product_ids)
      response = EsClient.search(
        index: ProductPageView.index_name,
        body: {
          size: 0,
          query: {
            bool: {
              filter: [
                { terms: { product_id: product_ids } },
                { range: { timestamp: { gte: window_starts_at.iso8601, lt: window_ends_at.iso8601 } } }
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
      # Team accounts run internal test products; taking down our own storefront on a traffic
      # spike would be worse than the thing we're preventing.
      return false if seller.is_team_member?
      return false if seller.suspended?

      true
    end

    def act_on(product:, candidate:)
      # The unpublish is the part that stops the sends, so it goes first and stands on its own:
      # nothing after it is allowed to undo it. Note and email are bookkeeping that tell a
      # human what happened and hand them the account decision.
      product.unpublish!(is_unpublished_by_admin: true)

      record_note_on_product(product:, content: comment_content(product:, candidate:))

      AdminMailer.inverted_sales_to_views_notify(
        product.id, candidate.sales_count, candidate.views_count, candidate.distinct_clients
      ).deliver_later(queue: "default")
    end

    # Without this an admin would find an unpublished product with no explanation on it.
    def record_note_on_product(product:, content:)
      product.comments.create!(
        author_name: NOTE_AUTHOR_NAME,
        comment_type: Comment::COMMENT_TYPE_FLAG_NOTE,
        content:
      )
    end

    def report_suspected_systemic_failure(candidates)
      ErrorNotifier.notify(
        "#{MAX_PRODUCTS_PER_RUN} or more products tripped the inverted sales-to-views check in one run, " \
          "which is more likely a broken page-view read than that many simultaneous incidents. " \
          "Took no action; someone should check Elasticsearch indexing lag and then these products by hand.",
        context: {
          source: NOTE_AUTHOR_NAME,
          product_ids: candidates.map(&:product_id),
          window_starts_at: window_starts_at.iso8601,
          window_ends_at: window_ends_at.iso8601
        }
      )
    end

    def comment_content(product:, candidate:)
      "Product '#{product.name}' unpublished automatically on #{Time.current.to_fs(:formatted_date_full_month)}: " \
        "#{number(candidate.sales_count)} free sales against #{number(candidate.views_count)} product page views " \
        "and only #{number(candidate.distinct_clients)} distinct browsers in the previous hour. " \
        "Sales far exceeding views means the checkouts did not come through the product page, and far exceeding " \
        "distinct browsers means they did not come from separate people, which together are the signature of " \
        "scripted checkouts using the receipt email as a mailer. Who ran the script is not established by this " \
        "signal — anyone can check out a public free product — so no account action was taken. Risk has been " \
        "emailed to review it."
    end

    def number(value)
      ActiveSupport::NumberHelper.number_to_delimited(value)
    end
end
