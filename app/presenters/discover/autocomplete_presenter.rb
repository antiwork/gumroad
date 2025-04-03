# frozen_string_literal: true

class Discover::AutocompletePresenter
  RECENT_SEARCH_LIMIT = 100
  PRODUCT_RESULT_COUNT = 5

  def initialize(query:, user:, browser_guid:)
    @query = query.to_s.downcase
    @user = user
    @browser_guid = browser_guid
  end

  def props
    { recent_searches: }.merge(product_results)
  end

  private
    attr_reader :query, :user, :browser_guid

    def product_results
      return { products: search_results(Link.partial_search_options(query:, size: PRODUCT_RESULT_COUNT)) } if query.present?

      recently_viewed_ids = ProductPageView.search(
        query: {
          bool: user.present? ? {
            must: { term: { user_id: user.id } },
          } : {
            must: { term: { browser_guid: } },
            must_not: { exists: { field: "user_id" } },
          }
        },
        sort: { timestamp: :desc },
        size: 5,
      ).map { _1["_source"]["product_id"] }

      if recently_viewed_ids.present?
        { products: search_results(Link.search_options(ids: recently_viewed_ids)), viewed: true }
      else
        { products: search_results(Link.search_options(size: PRODUCT_RESULT_COUNT)), viewed: false }
      end
    end

    def search_results(search_options)
      Link.search(search_options).records.map do |product|
        {
          name: product.name,
          url: product.long_url(recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION, layout: Product::Layout::DISCOVER, query:, autocomplete: true),
          seller_name: product.user.name.presence,
          thumbnail_url: product.thumbnail&.url,
        }
      end
    end

    def recent_searches
      searches = DiscoverSearchSuggestion.by_user_or_browser(user:, browser_guid:)
      if query.blank?
        searches.distinct.limit(5).pluck("discover_searches.query")
      else
        filter_recent_searches(searches.limit(RECENT_SEARCH_LIMIT).pluck("discover_searches.query").uniq).first(8)
      end
    end

    def filter_recent_searches(searches)
      query_words = query.split

      searches.select do |search|
        search_words = search.downcase.split

        (search_words & query_words).any? ||
          search_words.any? { |word| word.start_with?(query) } ||
          query.start_with?(search.downcase)
      end
    end
end
