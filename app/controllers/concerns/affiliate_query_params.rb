# frozen_string_literal: true

module AffiliateQueryParams
  def fetch_affiliate_id(params)
    id = (params[:affiliate_id].presence || params[:a].presence).to_i
    id.zero? ? nil : id
  end
end
