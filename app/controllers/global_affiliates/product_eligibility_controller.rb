# frozen_string_literal: true

class GlobalAffiliates::ProductEligibilityController < Sellers::BaseController
  class InvalidUrl < StandardError; end

  GUMROAD_DOMAINS = [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").domain } # Strip port (in test and development environment) and subdomains

  def show
    authorize [:products, :affiliated], :index?

    product_data = fetch_and_parse_product_data
    render json: { success: true, product: product_data }
  rescue InvalidUrl, URI::InvalidURIError, Addressable::URI::InvalidURIError
    render json: { success: false, error: "Please provide a valid Gumroad product URL" }
  end

  private
    # Resolve the pasted URL to a product, then shape exactly the fields the
    # affiliate-eligibility UI needs. We fetch the product's own public JSON
    # endpoint (GET /l/:permalink.json) to leverage its URL routing — that
    # handles short domains, subdomains, and custom permalinks for free — but
    # we read `recommendable?` from the model directly. Recommendability is an
    # affiliate-program eligibility concept, not part of the public product API
    # surface (ProductPresenter::PublicApiProps), so it must not be exposed
    # there; resolving it locally keeps that boundary clean.
    def fetch_and_parse_product_data
      uri = Addressable::URI.parse(params[:url])
      raise InvalidUrl unless GUMROAD_DOMAINS.include?(uri&.domain)
      uri.path = uri.path + ".json"

      response = HTTParty.get(uri.to_s)
      raise InvalidUrl unless response.ok?

      data = response.to_hash
      raise InvalidUrl unless data["api_version"] == ProductPresenter::PublicApiProps::API_VERSION && data["permalink"].present?

      id = data["id"]
      raise InvalidUrl if id.blank?

      product = Link.find_by_external_id(id)
      raise InvalidUrl if product.nil?

      {
        "name" => product.name,
        "formatted_price" => product.price_formatted_verbose,
        "recommendable" => product.recommendable?,
        "short_url" => product.long_url,
      }
    end
end
