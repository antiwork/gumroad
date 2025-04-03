# frozen_string_literal: true

class ProductUrlDetector
  class << self
    def regexps
      subdomain_matches + short_domain_matches + legacy_matches
    end

    private
      def short_domain_matches
        matches = case Rails.env.intern
                  when :test, :development
                    ["#{self.short_product_url}/l/"]
                  when :staging, :production
                    [
                      self.short_product_url(protocol: "http"),
                      self.short_product_url(protocol: "https")
                    ]
                  else
                    []
        end

        # Turn these into exact match regexps
        matches.map { |url| q url }
      end

      def subdomain_matches
        [self.subdomain_product_url_regexp]
      end

      def legacy_matches
        [
          q("#{UrlService.domain_with_protocol}/l/"),
          q("#{UrlService.root_domain_with_protocol}/l/")
        ]
      end

      def short_product_url(protocol: PROTOCOL)
        "#{protocol}://#{SHORT_DOMAIN}/"
      end

      def subdomain_product_url_regexp(protocol: PROTOCOL)
        [q("#{protocol}://"), Subdomain::USERNAME_REGEXP.source, q(".#{ROOT_DOMAIN}/l/")].join
      end

      def q(string)
        Regexp.quote string
      end
  end
end
