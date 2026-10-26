# frozen_string_literal: true

class Api::V2::Partner::CreatorsController < Api::V2::Partner::BaseController
  DEFAULT_LIMIT = 10
  MAX_LIMIT = 50

  # Creators ranked by their recent sales on Gumroad. Returns the order only, never the amounts.
  def top
    limit = (params[:limit].presence || DEFAULT_LIMIT).to_i.clamp(1, MAX_LIMIT)
    partner_sellers = partner_sellers_in_scope.to_a
    search_params = product_search_params(partner_sellers)
    return render_bad_request("Unknown category. Use a path from GET /v2/partner/categories.") if search_params.nil?
    return render json: { success: true, creators: [] } if partner_sellers.empty?

    response = Link.search(Link.search_options(search_params.merge(size: 0, include_top_creators: true, top_creators_size: limit)))
    user_ids = response.aggregations.dig("top_creators", "buckets").to_a.map { _1["key"].to_i }
    partner_sellers_by_user_id = partner_sellers.index_by(&:user_id)

    render json: {
      success: true,
      creators: user_ids.filter_map { partner_sellers_by_user_id[_1] }.map { PartnerSellerPresenter.new(partner_seller: _1).props },
    }
  end
end
