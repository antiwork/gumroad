# frozen_string_literal: true

class GlobalAffiliates::ProductEligibilityController < Sellers::BaseController
  class InvalidUrl < StandardError; end

  GUMROAD_DOMAINS = [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").domain } # Strip port (in test and development environment) and subdomains
  EXPECTED_PRODUCT_PARAMS = %w(name formatted_price recommendable short_url)

  def show
    authorize [:products, :affiliated], :index?

    product_data = fetch_and_parse_product_data
    render json: { success: true, product: product_data }
  rescue InvalidUrl
    render json: { success: false, error: "Please provide a valid Gumroad product URL" }
  end

  private
    def fetch_and_parse_product_data
      uri = Addressable::URI.parse(params[:url])
      raise InvalidUrl unless GUMROAD_DOMAINS.include?(uri&.domain)
      uri.path = uri.path + ".json"

      response = HTTParty.get(uri.to_s)
      raise InvalidUrl unless response.ok?

      data = response.to_hash.slice(*EXPECTED_PRODUCT_PARAMS)
      raise InvalidUrl unless data.keys == EXPECTED_PRODUCT_PARAMS

      data
    end
end
