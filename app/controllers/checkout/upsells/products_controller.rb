# frozen_string_literal: true

class Checkout::Upsells::ProductsController < ApplicationController
  include CustomDomainConfig

  MAX_PRODUCTS = 25

  PRODUCT_INCLUDES = [
    :alive_prices,
    :skus_alive_not_default,
    :variant_categories_alive,
    :product_review_stat,
    { alive_variants: { variant_category: :link },
      thumbnail_alive: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } },
      display_asset_previews: { file_attachment: { blob: { variant_records: { image_attachment: :blob } } } } },
  ].freeze

  def index
    seller = user_by_domain(request.host) || current_seller
    return render json: [] unless seller

    products = WithMaxExecutionTime.timeout_queries(seconds: 10) do
      # The picker UI only ever shows MAX_PRODUCTS results at a time, so sellers
      # with more products than that rely on the `query` param to search the rest
      # of their catalog server-side. Without it, older products could never be
      # selected as upsells. The picker also lists variants as "Product (Variant)"
      # options, so the search matches variant names too — otherwise typing a
      # variant name would return nothing.
      scope = seller.products.eligible_for_content_upsells
      if params[:query].present?
        like_pattern = "%#{Link.sanitize_sql_like(params[:query])}%"
        scope = scope
          .left_joins(:alive_variants)
          .where("links.name LIKE :query OR base_variants.name LIKE :query", query: like_pattern)
          .distinct
      end
      scope
        .includes(*PRODUCT_INCLUDES)
        .order(created_at: :desc, id: :desc)
        .limit(MAX_PRODUCTS)
        .to_a
    end
    render json: products.map { |product| Checkout::Upsells::ProductPresenter.new(product).product_props }
  rescue WithMaxExecutionTime::QueryTimeoutError
    render json: []
  end

  def show
    product = WithMaxExecutionTime.timeout_queries(seconds: 10) do
      Link.eligible_for_content_upsells
          .includes(*PRODUCT_INCLUDES)
          .find_by_external_id!(params[:id])
    end

    render json: Checkout::Upsells::ProductPresenter.new(product).product_props
  rescue WithMaxExecutionTime::QueryTimeoutError
    render json: { error: "Request timed out" }, status: :gateway_timeout
  end
end
