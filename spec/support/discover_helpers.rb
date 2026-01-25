# frozen_string_literal: true

module DiscoverHelpers
  def taxonomy_url(taxonomy_path, query_params = {})
    UrlService.discover_full_path(taxonomy_path, query_params)
  end

  def discover_url(host: nil, **query_params)
    base_url = host || UrlService.discover_domain_with_protocol
    path = Rails.application.routes.url_helpers.discover_path
    uri = Addressable::URI.parse("#{base_url}#{path}")
    uri.query = query_params.compact.to_query if query_params.any?
    uri.to_s
  end
end
