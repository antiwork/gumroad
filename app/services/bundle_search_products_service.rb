# frozen_string_literal: true

class BundleSearchProductsService
  PER_PAGE = 10

  attr_reader :bundle, :query, :page, :all, :seller

  def initialize(bundle:, seller:, query: nil, page: 1, all: false)
    @bundle = bundle
    @seller = seller
    @query = query
    @page = [page.to_i, 1].max
    @all = all
  end

  def call
    search_params = build_search_params
    product_options = Link.search_options(search_params)
    product_response = Link.search(product_options)
    products = product_response.records.map { BundlePresenter.bundle_product(product: _1) }

    total_count = product_response.results.total
    has_more = !all && (page * PER_PAGE) < total_count

    { products:, has_more:, page:, total_count: }
  end

  private
    def build_search_params
      from = (page - 1) * PER_PAGE
      params = {
        query:,
        from:,
        sort: ProductSortKey::FEATURED,
        user_id: seller.id,
        is_subscription: false,
        is_bundle: false,
        is_alive: true,
        is_call: false,
        exclude_ids: [ObfuscateIds.decrypt(bundle.external_id)],
      }
      params[:size] = all ? 1000 : PER_PAGE
      params
    end
end
