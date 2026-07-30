# frozen_string_literal: true

class UrlService
  class << self
    def domain_with_protocol
      "#{PROTOCOL}://#{DOMAIN}"
    end

    def root_domain_with_protocol
      "#{PROTOCOL}://#{ROOT_DOMAIN}"
    end

    def discover_domain_with_protocol
      "#{PROTOCOL}://#{DISCOVER_DOMAIN}"
    end

    def api_domain_with_protocol
      "#{PROTOCOL}://#{API_DOMAIN}"
    end

    def short_domain_with_protocol
      "#{PROTOCOL}://#{SHORT_DOMAIN}"
    end

    def discover_full_path(taxonomy_path, query_params = nil)
      discover_url = Rails.application.routes.url_helpers.discover_url({
                                                                         protocol: PROTOCOL,
                                                                         host: DISCOVER_DOMAIN
                                                                       })
      uri = Addressable::URI.parse(discover_url)
      uri.path = taxonomy_path
      uri.query = query_params.compact.to_query if query_params.present?
      uri.to_s
    end

    def widget_script_base_url(seller: nil)
      custom_domain_with_protocol(seller) || root_domain_with_protocol
    end

    def widget_product_link_base_url(seller: nil, allow_custom_domain: true)
      (allow_custom_domain && custom_domain_with_protocol(seller)) || seller&.subdomain_with_protocol || root_domain_with_protocol
    end

    private
      def custom_domain_with_protocol(seller)
        return if Rails.env.development?
        return unless seller.present? && seller.custom_domain&.active?

        domain = seller.custom_domain.domain
        is_strictly_pointing_to_gumroad = CustomDomainVerificationService.new(domain:).domains_pointed_to_gumroad.include?(domain)

        "#{PROTOCOL}://#{domain}" if is_strictly_pointing_to_gumroad
      end
  end
end
