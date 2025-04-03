# frozen_string_literal: true

class AffiliateRedirectController < ApplicationController
  include AffiliateCookie

  def set_cookie_and_redirect
    affiliate = Affiliate.find_by_external_id_numeric(params[:affiliate_id].to_i)
    if affiliate.nil?
      Rails.logger.info("No affiliate found for id #{params[:affiliate_id]}")
      return e404
    end

    create_affiliate_id_cookie(affiliate)

    redirect_to redirect_url(affiliate), allow_other_host: true
  end

  private
    def redirect_url(affiliate)
      product = Link.find_by(unique_permalink: params[:unique_permalink]) if params[:unique_permalink].present?
      final_destination_url = affiliate.final_destination_url(product:)
      uri = Addressable::URI.parse(final_destination_url)

      request_uri = Addressable::URI.parse(request.url)

      query_values = uri.query_values || {}
      query_values.merge!(request_uri.query_values || {})
      query_values["affiliate_id"] = params[:affiliate_id] if affiliate.destination_url.present?
      uri.query_values = query_values unless query_values.empty?
      uri.to_s
    end
end
