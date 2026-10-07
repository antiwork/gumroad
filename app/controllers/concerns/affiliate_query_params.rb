# frozen_string_literal: true

module AffiliateQueryParams
  def fetch_affiliate_id(params)
    raw_id = Array.wrap(params[:affiliate_id].presence || params[:a].presence).first
    # A nested shape (?affiliate_id[key]=1) parses to Parameters, not a scalar.
    return nil unless raw_id.is_a?(String)

    id = raw_id.to_i
    id.zero? ? nil : id
  end
end
