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
      uri = Addressable::URI.parse(host_relative(final_destination_url.strip))

      request_uri = Addressable::URI.parse(request.url)

      query_values = uri.query_values || {}
      query_values.merge!(request_uri.query_values || {})
      query_values["affiliate_id"] = params[:affiliate_id] if affiliate.destination_url.present?
      uri.query_values = query_values unless query_values.empty?
      uri.to_s
    end

    # A per-product destination_url is creator-supplied and unvalidated: unlike DirectAffiliate,
    # ProductAffiliate does not include Affiliate::DestinationUrlValidations, and
    # final_destination_url prefers it. So it can be path-relative ("products/foo"), which
    # Rails 8.1 refuses to redirect to. Before 8.1 those did not work either — they became
    # "https://gumroad.comproducts/foo" — so treat them as paths on this host, the same repair
    # SafeRedirectPathService makes for `next` params.
    def host_relative(destination)
      return destination if destination.blank?
      return destination if destination.match?(%r{\A([a-z][a-z\d\-+.]*:|//)}i)
      return destination if destination.start_with?("/", "?")

      "/#{destination}"
    end
end
