# frozen_string_literal: true

class HomePageLinkService
  PAGES = [:privacy, :terms, :about, :features, :university, :pricing, :affiliates, :prohibited]
  private_constant :PAGES

  ROOT_DOMAIN_WITH_PROTCOL = UrlService.root_domain_with_protocol
  private_constant :ROOT_DOMAIN_WITH_PROTCOL

  class << self
    PAGES.each do |page|
      define_method(page) { prepend_host("/#{page}") }
    end

    def root
      ROOT_DOMAIN_WITH_PROTCOL
    end

    private
      def prepend_host(page)
        "#{ROOT_DOMAIN_WITH_PROTCOL}#{page}"
      end
  end
end
