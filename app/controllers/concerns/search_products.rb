# frozen_string_literal: true

module SearchProducts
  BLACK_FRIDAY_CODE = "BLACKFRIDAY2025"
  ALLOWED_OFFER_CODES = [BLACK_FRIDAY_CODE].freeze

  private
    def search_products(params)
      filetype_options = Link.filetype_options(params)
      filetype_response = Link.search(filetype_options)
      taxonomy_attribute_response = Link.search(Link.taxonomy_attribute_options(params)) if params[:taxonomy_id].present?
      product_options = Link.search_options(params.merge(track_total_hits: true))

      product_response = Link.search(product_options)
      {
        total: product_response.results.total,
        tags_data: product_response.aggregations["tags.keyword"]["buckets"].to_a.map(&:to_h),
        filetypes_data: filetype_response.aggregations["filetypes.keyword"]["buckets"].to_a.map(&:to_h),
        taxonomy_attributes_data: taxonomy_attributes_data(params, taxonomy_attribute_response),
        products: product_response.records
      }
    end

    def taxonomy_attributes_data(params, taxonomy_attribute_response)
      return [] if params[:taxonomy_id].blank? || taxonomy_attribute_response.nil?

      attributes = Taxonomy.find_by(id: params[:taxonomy_id])&.taxonomy_attributes&.select(&:filterable?) || []
      return [] if attributes.empty?

      buckets_by_key = taxonomy_attribute_response.aggregations["taxonomy_attribute_filters"]["buckets"].to_a.index_by { |bucket| bucket["key"] }
      attributes.filter_map do |attribute|
        filters = attribute.filter_options.filter_map do |option|
          token = attribute.filter_token_for(option)
          bucket = buckets_by_key[token]
          { key: token, label: attribute.filter_label_for(option), doc_count: bucket ? bucket["doc_count"] : 0 } if token
        end
        next if filters.empty?

        { name: attribute.name, label: attribute.label, filters: }
      end
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

      if search_params[:taxonomy_attribute_filters].is_a?(String)
        search_params[:taxonomy_attribute_filters] = search_params[:taxonomy_attribute_filters].split(",").map(&:squish)
      elsif search_params[:taxonomy_attribute_filters].is_a?(ActionController::Parameters) || search_params[:taxonomy_attribute_filters].is_a?(Hash)
        search_params[:taxonomy_attribute_filters] = search_params[:taxonomy_attribute_filters].values.filter_map { |filter| scalar_search_value(filter)&.to_s&.squish }
      end

      if search_params[:ids].is_a?(String)
        search_params[:ids] = search_params[:ids].split(",").map(&:strip)
      end

      # These reach ES as `terms` clauses, which reject a nested structure with a 400.
      %i[tags filetypes ids exclude_ids taxonomy_attribute_filters].each do |key|
        next unless search_params[key].is_a?(Array)

        search_params[key] = search_params[key].filter_map { |element| scalar_search_value(element)&.to_s }
      end

      if search_params[:taxonomy_attribute_filters].is_a?(Array)
        valid_tokens = TaxonomyAttribute.valid_filter_tokens
        # Allowlist before the cap: otherwise 20 junk tokens can push the one real token past
        # the limit and silently widen the result set.
        search_params[:taxonomy_attribute_filters] =
          search_params[:taxonomy_attribute_filters]
            .uniq
            .select { |token| valid_tokens.include?(token) }
            .first(Product::Searchable::MAX_TAXONOMY_ATTRIBUTE_FILTER_TOKENS)
      end

      # search_options coerces each of these unconditionally (`.to_i`, `.to_f`) or hands it to ES
      # as a scalar; a crafted `?query[][]=x` would otherwise 500 a public profile URL.
      %i[query rating min_price max_price sort recommended_by from size].each do |key|
        search_params[key] = scalar_search_value(search_params[key]) if search_params.key?(key)
      end

      search_params[:from] = search_params[:from].to_i if search_params[:from].present?
      # search_options computes MAX_RESULT_WINDOW - size and clamps against it, so an oversized
      # or negative size raises on the range rather than returning nothing.
      search_params[:size] = search_params[:size].to_i.clamp(0, Link::MAX_RESULT_WINDOW) if search_params[:size].present?

      search_params.delete(:search) unless search_params[:search].is_a?(Hash)

      search_params
    end

    # Collapses a crafted nested param to the scalar the search layer expects, or nil when it has
    # no scalar reading. A deeper nesting collapses to nil rather than being unwrapped further.
    def scalar_search_value(value)
      value = value.first if value.is_a?(Array)
      value.is_a?(String) || value.is_a?(Numeric) ? value : nil
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
