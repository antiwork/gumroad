# frozen_string_literal: true

class Discover::CanonicalUrlPresenter
  # `/` on DISCOVER_DOMAIN is the marketing homepage (home#about), not Discover.
  INDEX_PATH = "/discover"

  def self.canonical_url(params)
    if params.values_at(:taxonomy, :query, :tags).all?(&:blank?)
      return UrlService.discover_full_path(INDEX_PATH)
    end

    path = params[:taxonomy].presence || INDEX_PATH
    valid_canonical_params = params.permit(:sort, :query, :min_price, :max_price, :rating, tags: [], filetypes: [])
                                   .to_h
                                   .to_h { |key, value| [key, key == "query" ? to_canonical_query(value) : to_canonical_value(value)] }
                                   .select { |_, v| v.present? }

    UrlService.discover_full_path(path, valid_canonical_params)
  end

  def self.to_canonical_value(param_value)
    param_value.is_a?(Array) ? param_value.sort.join(",") : param_value
  end
  private_class_method :to_canonical_value

  # Search matches case- and whitespace-insensitively, so those spellings are one page.
  def self.to_canonical_query(query)
    query.to_s.squish.downcase
  end
  private_class_method :to_canonical_query
end
