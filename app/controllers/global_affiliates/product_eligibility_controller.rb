# frozen_string_literal: true

class GlobalAffiliates::ProductEligibilityController < Sellers::BaseController
  class InvalidUrl < StandardError; end

  GUMROAD_DOMAINS = [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").domain } # Strip port (in test and development environment) and subdomains
  # The domain list drops the port, so test.gumroad.com:9000 would otherwise pass and we would open a
  # connection to whatever port the caller names. Allow only the ports our own domains use, plus the
  # web defaults so a pasted http:// URL still resolves.
  GUMROAD_PORTS = ([80, 443] + [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").inferred_port }).uniq.freeze
  # HTTParty's own redirect budget. We follow the hops ourselves so each one can be checked first.
  MAX_REDIRECTS = 5
  FETCH_TIMEOUT_SECONDS = 5

  def show
    authorize [:products, :affiliated], :index?

    product_data = fetch_and_parse_product_data
    render json: { success: true, product: product_data }
  rescue InvalidUrl, JSON::ParserError, HTTParty::Error, *INTERNET_EXCEPTIONS
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
      response = fetch_product_json(validate_gumroad_url(params[:url]))
      raise InvalidUrl unless response.ok?

      data = response.parsed_response
      raise InvalidUrl unless data.is_a?(Hash) && data["api_version"] == ProductPresenter::PublicApiProps::API_VERSION && data["permalink"].present?

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

    # Scheme, host and port all have to be ours. The registrable-domain check alone let any port
    # through, and the fetch follows redirects — including the one an affiliate's stored
    # destination_url produces, which can name any host.
    def validate_gumroad_url(url)
      uri = Addressable::URI.parse(url)
      raise InvalidUrl unless %w[http https].include?(uri&.scheme) && GUMROAD_DOMAINS.include?(uri.domain) && GUMROAD_PORTS.include?(uri.inferred_port)

      uri
    end

    def fetch_product_json(uri)
      uri.path = "#{uri.path}.json"

      MAX_REDIRECTS.times do
        response = HTTParty.get(uri.to_s, timeout: FETCH_TIMEOUT_SECONDS, follow_redirects: false)
        return response unless response.code.between?(300, 399)

        location = response.response["location"].to_s
        raise InvalidUrl if location.blank?

        uri = validate_gumroad_url(Addressable::URI.join(uri, location).to_s)
      end

      raise InvalidUrl
    end
end
