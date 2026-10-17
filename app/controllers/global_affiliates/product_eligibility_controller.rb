# frozen_string_literal: true

class GlobalAffiliates::ProductEligibilityController < Sellers::BaseController
  class InvalidUrl < StandardError; end

  GUMROAD_DOMAINS = [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").domain } # Strip port (in test and development environment) and subdomains
  # The domain list drops the port, so test.gumroad.com:9000 would otherwise pass and we would open a
  # connection to whatever port the caller names. Allow only the ports our own domains use, plus the
  # web defaults so a pasted http:// URL still resolves.
  WEB_PORTS = [80, 443]
  GUMROAD_PORTS = (WEB_PORTS + [ROOT_DOMAIN, SHORT_DOMAIN, DOMAIN].map { |domain| Addressable::URI.parse("#{PROTOCOL}://#{domain}").inferred_port }).uniq.freeze
  # Matches HTTParty's own budget. We follow the hops ourselves so each one can be checked first.
  MAX_REDIRECTS = 5
  FETCH_TIMEOUT_SECONDS = 5

  def show
    authorize [:products, :affiliated], :index?

    product_data = fetch_and_parse_product_data
    render json: { success: true, product: product_data }
  rescue InvalidUrl, URI::Error, JSON::ParserError, Errno::ETIMEDOUT, *INTERNET_EXCEPTIONS
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
      product = development_product(params[:url]) || product_from_public_json(params[:url])

      {
        "name" => product.name,
        "formatted_price" => product.price_formatted_verbose,
        "recommendable" => product.recommendable?,
        "short_url" => product.long_url,
      }
    end

    def product_from_public_json(url)
      response = fetch_product_json(validate_gumroad_uri(url))
      raise InvalidUrl unless response.is_a?(Net::HTTPOK)

      data = JSON.parse(response.body.to_s)
      raise InvalidUrl unless data.is_a?(Hash) && data["api_version"] == ProductPresenter::PublicApiProps::API_VERSION && data["permalink"].present?

      id = data["id"]
      raise InvalidUrl if id.blank?

      Link.find_by_external_id(id) || raise(InvalidUrl)
    end

    # Development origins resolve to loopback, which SsrfFilter refuses. Resolve product URLs on them
    # in-process with LinksController#show's lookup instead; nothing is fetched.
    def development_product(url)
      return unless Rails.env.development?

      uri = URI(url.to_s)
      host = uri.host.to_s.downcase
      return unless uri.scheme == PROTOCOL && uri.userinfo.nil? && host.present?

      root = URI("#{PROTOCOL}://#{ROOT_DOMAIN}")
      short = URI("#{PROTOCOL}://#{SHORT_DOMAIN}")
      if host == short.host && uri.port == short.port
        permalink = uri.path[%r{\A/([^/]+)\z}, 1]
      elsif uri.port == root.port && [root.host, URI("#{PROTOCOL}://#{DOMAIN}").host].include?(host)
        permalink = uri.path[%r{\A/l/([^/]+)\z}, 1]
      elsif uri.port == root.port && host.end_with?(".#{root.host}")
        seller = Subdomain.find_seller_by_hostname(host) || raise(InvalidUrl)
        permalink = uri.path[%r{\A/l/([^/]+)\z}, 1]
      else
        return
      end
      raise InvalidUrl if permalink.blank?

      product = Link.fetch_leniently(permalink, user: seller)
      raise InvalidUrl if product.nil? || product.banned? || product.user.deleted?

      product
    end

    # Scheme, host and port all have to be ours, checked on the same stdlib URI that SsrfFilter
    # connects with so the two cannot parse the host differently. Redirects can name any host
    # (an affiliate's destination_url does), so every hop comes back through here.
    def validate_gumroad_uri(url)
      uri = URI(url.to_s)
      raise InvalidUrl unless %w[http https].include?(uri.scheme) && uri.userinfo.nil? && uri.hostname.present? &&
                              GUMROAD_DOMAINS.include?(PublicSuffix.domain(uri.hostname, ignore_private: true)) &&
                              GUMROAD_PORTS.include?(uri.port)

      uri
    end

    # SsrfFilter refuses private and reserved addresses and connects to the address it checked, so a
    # second DNS answer cannot redirect the socket. It never follows a redirect itself.
    def fetch_product_json(uri)
      uri.path = "#{uri.path}.json"
      redirects = 0

      loop do
        response = SsrfFilter.get(uri, max_redirects: 0, allow_unfollowed_redirects: true,
                                       http_options: { open_timeout: FETCH_TIMEOUT_SECONDS, read_timeout: FETCH_TIMEOUT_SECONDS })
        return response unless response.is_a?(Net::HTTPRedirection)

        # The budget counts hops, not the first request.
        redirects += 1
        raise InvalidUrl if redirects > MAX_REDIRECTS

        location = response["location"]
        raise InvalidUrl if location.blank?

        uri = validate_gumroad_uri(uri.merge(location))
      end
    end
end
