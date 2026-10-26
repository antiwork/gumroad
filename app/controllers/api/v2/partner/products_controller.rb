# frozen_string_literal: true

class Api::V2::Partner::ProductsController < Api::V2::Partner::BaseController
  DEFAULT_PER_PAGE = 20
  MAX_PER_PAGE = 100

  def index
    return render_bad_request("page and per_page must be integers.") unless integer_params?(:page, :per_page)

    page = [params[:page].to_i, 1].max
    per_page = (params[:per_page].presence || DEFAULT_PER_PAGE).to_i.clamp(1, MAX_PER_PAGE)
    # Elasticsearch cannot page past its result window; search_options would silently repeat the last page.
    if page * per_page > Link::MAX_RESULT_WINDOW
      return render_bad_request("Results are available up to #{Link::MAX_RESULT_WINDOW}. Narrow the request with external_user_id or other filters.")
    end
    partner_sellers = partner_sellers_in_scope.to_a
    search_params = product_search_params(partner_sellers)
    return render_bad_request("Unknown category. Use a path from GET /v2/partner/categories.") if search_params.nil?
    return render_products([], partner_sellers:, total: 0, page:, per_page:) if partner_sellers.empty?

    # `from` is 1-based in search_options.
    response = Link.search(Link.search_options(search_params.merge(from: (page - 1) * per_page + 1, size: per_page, track_total_hits: true)))
    product_ids = response.records.ids.map(&:to_i)
    products_by_id = Link.includes(ProfilePresenter::PublicApiProps::PRODUCT_ASSOCIATIONS_FOR_VISIBILITY).where(id: product_ids).index_by(&:id)
    products = product_ids.filter_map { products_by_id[_1] }
    # The search index has no stock, so hidden sold-out products are removed per page, as on the
    # profile (ProfileSectionsPresenter). `total` drops only by the ones on this page.
    visible_products = products.reject { |product| product.hide_sold_out_variants? && product.remaining_for_sale_count == 0 }
    total = response.results.total - (products.size - visible_products.size)

    render_products(visible_products, partner_sellers:, total:, page:, per_page:)
  end

  private
    def render_products(products, partner_sellers:, total:, page:, per_page:)
      partner_sellers_by_user_id = partner_sellers.index_by(&:user_id)
      preload_users(partner_sellers_by_user_id.values_at(*products.map(&:user_id).uniq))

      render json: {
        success: true,
        products: products.map { PartnerProductPresenter.new(product: _1, partner_seller: partner_sellers_by_user_id.fetch(_1.user_id)).props },
        total:,
        page:,
        per_page:,
      }
    end
end
