# frozen_string_literal: true

module AffiliateQueryParams
  def fetch_affiliate_id(params)
    raw_id = params[:affiliate_id].presence || params[:a].presence
    id = Array.wrap(raw_id).first.to_i
    id.zero? ? nil : id
  end
end
