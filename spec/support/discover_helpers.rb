# frozen_string_literal: true

module DiscoverHelpers
  def taxonomy_url(taxonomy_path, query_params = {})
    UrlService.discover_full_path(taxonomy_path, query_params)
  end
end
