# frozen_string_literal: true

class Discover::RecentlyViewedPresenter
  PRODUCT_COUNT = 8
  VIEW_WINDOW = 30.days

  # One-way key for an anonymous identity: the raw guid is an httponly cookie that unlocks the
  # visitor's view history, so it never leaves the server — not to JS and not to logs. Joins
  # against purchases hash purchases.browser_guid the same way.
  def self.anonymous_key(browser_guid)
    Digest::SHA256.hexdigest(browser_guid)[0, 16]
  end

  def initialize(user:, browser_guid:, request:, include_rated_as_adult: false)
    @user = user
    @browser_guid = browser_guid
    @request = request
    @include_rated_as_adult = include_rated_as_adult
  end

  def props
    return nil if user.blank? && browser_guid.blank?

    views = recent_views
    return nil if views.blank?

    # First view per product wins because views are sorted desc, i.e. the most recent one.
    viewed_at_by_product_id = views.each_with_object({}) { |v, h| h[v["_source"]["product_id"]] ||= v["_source"]["timestamp"] }
    product_ids = viewed_at_by_product_id.keys.first(PRODUCT_COUNT)
    products_by_id = Link.search(
      Link.search_options(ids: product_ids, size: PRODUCT_COUNT, include_rated_as_adult:)
    ).records.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).index_by(&:id)

    cards = product_ids.filter_map do |id|
      product = products_by_id[id]
      next if product.nil?

      ProductPresenter.card_for_web(
        product:,
        request:,
        recommended_by: RecommendationType::GUMROAD_RECENTLY_VIEWED_RECOMMENDATION,
        target: Product::Layout::DISCOVER,
        compute_description: false,
      ).merge(viewed_at: viewed_at_by_product_id.fetch(id))
    end
    return nil if cards.blank?

    # Anonymous visitors are keyed server-side by the _gumroad_guid cookie, which the client
    # can't read (httponly). Without this, every anonymous browser shares one "anonymous"
    # localStorage key, so replacing the cookie (cleared, new profile) leaves the new
    # identity's history hidden behind the old identity's Clear cutoff. Hashed rather than
    # passed raw since the guid is otherwise never exposed to JS.
    { products: cards, anonymous_key: user.present? ? nil : self.class.anonymous_key(browser_guid) }
  end

  private
    attr_reader :user, :browser_guid, :request, :include_rated_as_adult

    def recent_views
      identity = if user.present?
        { must: [{ term: { user_id: user.id } }, timestamp_filter] }
      else
        {
          must: [{ term: { browser_guid: } }, timestamp_filter],
          must_not: { exists: { field: "user_id" } },
        }
      end

      ProductPageView.search(
        query: { bool: identity },
        collapse: { field: :product_id },
        sort: { timestamp: :desc },
        size: PRODUCT_COUNT,
      ).to_a
    end

    def timestamp_filter
      { range: { timestamp: { gte: VIEW_WINDOW.ago.iso8601 } } }
    end
end
