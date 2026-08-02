# frozen_string_literal: true

module SearchProducts
  BLACK_FRIDAY_CODE = "BLACKFRIDAY2025"
  ALLOWED_OFFER_CODES = [BLACK_FRIDAY_CODE].freeze

  private
    def search_products(params)
      filetype_options = Link.filetype_options(params)
      filetype_response = Link.search(filetype_options)
      product_options = Link.search_options(params.merge(track_total_hits: true))

      product_response = Link.search(product_options)
      {
        total: product_response.results.total,
        tags_data: product_response.aggregations["tags.keyword"]["buckets"].to_a.map(&:to_h),
        filetypes_data: filetype_response.aggregations["filetypes.keyword"]["buckets"].to_a.map(&:to_h),
        products: product_response.records
      }
    end

    # Value-shape coercions only. Split out from format_search_params! so callers that build
    # their own params hash (ProfileSectionsPresenter reads the raw query string) get the same
    # normalization — search_options coerces these unconditionally (`.to_i`, `.to_f`,
    # `each_with_index`), so an unexpected shape 400s Elasticsearch or raises.
    def normalize_search_param_values!(search_params)
      if search_params[:tags].is_a?(String)
        search_params[:tags] = search_params[:tags].split(",").map { |t| t.tr("-", " ").squish.downcase }
      elsif search_params[:tags].is_a?(ActionController::Parameters) || search_params[:tags].is_a?(Hash)
        search_params[:tags] = search_params[:tags].values.map { |t| t.to_s.tr("-", " ").squish.downcase }
      end

      if search_params[:filetypes].is_a?(String)
        search_params[:filetypes] = search_params[:filetypes].split(",").map { |f| f.squish.downcase }
      end

      if search_params[:ids].is_a?(String)
        search_params[:ids] = search_params[:ids].split(",").map(&:strip)
      end

      search_params[:from] = Array.wrap(search_params[:from]).first.to_i if search_params[:from].present?

      if search_params[:size].is_a?(String)
        search_params[:size] = search_params[:size].to_i
      elsif search_params[:size].is_a?(Array)
        search_params[:size] = search_params[:size].first.to_i
      end

      # search_options builds `simple_query_string` and numeric clauses from these; none accepts
      # a nested structure, and it coerces unconditionally (`.to_i`, `.to_f`). Take the first
      # element of an array (matching how :from and :size already collapse) and drop a hash,
      # whose values have no scalar reading.
      %i[query rating min_price max_price sort recommended_by].each do |key|
        value = search_params[key]
        next unless value.is_a?(Array) || value.is_a?(Hash) || value.is_a?(ActionController::Parameters)

        search_params[key] = value.is_a?(Array) ? value.first : nil
      end

      search_params.delete(:search) unless search_params[:search].is_a?(Hash)

      search_params
    end

    def format_search_params!
      normalize_search_param_values!(params)

      params[:offer_code] = "__no_match__" if params[:offer_code].present? && !offer_codes_search_feature_active?(params)
    end

    def offer_codes_search_feature_active?(params)
      return false if ALLOWED_OFFER_CODES.exclude?(params[:offer_code])

      Feature.active?(:offer_codes_search) || (params[:feature_key].present? && ActiveSupport::SecurityUtils.secure_compare(params[:feature_key], ENV["SECRET_FEATURE_KEY"].to_s))
    end
end
