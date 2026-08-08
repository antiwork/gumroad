# frozen_string_literal: true

class Discover::RecentlyViewedPresenter
  PRODUCT_COUNT = 8
  VIEW_WINDOW = 30.days
  # Views are one event per page load, so over-fetch before deduplicating to product ids.
  VIEW_FETCH_SIZE = 50

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

    { products: cards }
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
        sort: { timestamp: :desc },
        size: VIEW_FETCH_SIZE,
      ).to_a
    end

    def timestamp_filter
      { range: { timestamp: { gte: VIEW_WINDOW.ago.iso8601 } } }
    end
end
