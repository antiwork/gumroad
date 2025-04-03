# frozen_string_literal: true

class Discover::CanonicalUrlPresenter
  def self.canonical_url(params)
    if params.values_at(:taxonomy, :query, :tags).all?(&:blank?)
      return UrlService.discover_full_path("/")
    end

    path = params[:taxonomy] || "/"
    valid_canonical_params = params.permit(:sort, :query, :min_price, :max_price, :rating, tags: [], filetypes: [])
                                   .to_h
                                   .transform_values { |value| to_canonical_value(value) }
                                   .select { |_, v| v.present? }

    UrlService.discover_full_path(path, valid_canonical_params)
  end

  def self.to_canonical_value(param_value)
    param_value.is_a?(Array) ? param_value.sort.join(",") : param_value
  end
  private_class_method :to_canonical_value
end
