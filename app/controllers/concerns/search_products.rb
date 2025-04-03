# frozen_string_literal: true

module SearchProducts
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

    def format_search_params!
      if params[:tags].is_a?(String)
        params[:tags] = params[:tags].split(",").map { |t| t.tr("-", " ").squish.downcase }
      end

      if params[:filetypes].is_a?(String)
        params[:filetypes] = params[:filetypes].split(",").map { |f| f.squish.downcase }
      end

      if params[:size].is_a?(String)
        params[:size] = params[:size].to_i
      end
    end
end
