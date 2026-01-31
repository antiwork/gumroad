# frozen_string_literal: true

class DiscoverController < ApplicationController
  RECOMMENDED_PRODUCTS_COUNT = 8
  INITIAL_PRODUCTS_COUNT = 36

  include ActionView::Helpers::NumberHelper, RecommendationType, CreateDiscoverSearch,
          DiscoverCuratedProducts, SearchProducts, AffiliateCookie

  before_action :set_affiliate_cookie, only: [:index]

  def index
    format_search_params!

    @hide_layouts = true
    @card_data_handling_mode = CardDataHandlingMode.get_card_data_handling_mode(logged_in_user)

    if params[:sort].blank? && curated_products.present?
      params[:sort] = ProductSortKey::CURATED
      params[:curated_product_ids] = (curated_products[RECOMMENDED_PRODUCTS_COUNT..] || []).map { _1.product.id }
    end

    if !show_curated_products? && params.except(:controller, :action, :format, :taxonomy).blank?
      params[:from] = RECOMMENDED_PRODUCTS_COUNT + 1
    end

    if taxonomy
      params[:taxonomy_id] = taxonomy.id
      params[:include_taxonomy_descendants] = true
    end

    params[:include_rated_as_adult] = logged_in_user&.show_nsfw_products?
    params[:size] = INITIAL_PRODUCTS_COUNT

    @search_results = search_products(params)
    @search_results[:products] = @search_results[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).map do |product|
      ProductPresenter.card_for_web(
        product:,
        request:,
        recommended_by: RecommendationType::GUMROAD_SEARCH_RECOMMENDATION,
        target: Product::Layout::DISCOVER,
        compute_description: false,
        query: params[:query],
        offer_code: params[:offer_code]
      )
    end

    create_discover_search!(query: params[:query], taxonomy: @taxonomy) if is_searching?

    prepare_discover_page

    @react_discover_props = {
      search_results: @search_results,
      currency_code: logged_in_user&.currency_type || "usd",
      taxonomies_for_nav:,
      recommended_products: recommendations,
      curated_product_ids: curated_products.map { _1.product.external_id },
      search_offset: params[:from] || 0,
      show_black_friday_hero: black_friday_feature_active?,
      is_black_friday_page: params[:offer_code] == SearchProducts::BLACK_FRIDAY_CODE,
      black_friday_offer_code: SearchProducts::BLACK_FRIDAY_CODE,
      black_friday_stats: black_friday_feature_active? ? BlackFridayStatsService.fetch_stats : nil,
    }
  end

  def recommended_products
    render json: recommendations
  end

  private
    def recommendations
      # Don't show any recommended/featured products when offer codes are present
      return [] if params[:offer_code].present?

      if show_curated_products?
        curated_products.take(RECOMMENDED_PRODUCTS_COUNT).map do |product_info|
          ProductPresenter.card_for_web(
            product: product_info.product,
            request:,
            recommended_by: product_info.recommended_by,
            target: product_info.target,
            recommender_model_name: product_info.recommender_model_name,
            affiliate_id: product_info.affiliate_id,
          )
        end
      else
        products = if taxonomy.present?
          search_params = { size: RECOMMENDED_PRODUCTS_COUNT, taxonomy_id: taxonomy.id, include_taxonomy_descendants: true }
          search_products(search_params)[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
        else
          all_top_products = Rails.cache.fetch("discover_all_top_products", expires_in: 1.day) do
            products = []
            Taxonomy.roots.each do |top_taxonomy|
              search_params = { size: RECOMMENDED_PRODUCTS_COUNT, taxonomy_id: top_taxonomy.id, include_taxonomy_descendants: true }
              top_products = search_products(search_params)[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
              products.concat(top_products)
            end
            products
          end

          all_top_products.sample(RECOMMENDED_PRODUCTS_COUNT)
        end

        products.map do |product|
          ProductPresenter.card_for_web(
            product:,
            request:,
            recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION,
            target: Product::Layout::DISCOVER
          )
        end
      end
    end

    def show_curated_products?
      return false if params[:offer_code].present?
      !taxonomy && curated_products.any?
    end

    def is_searching?
      params.values_at(:query, :tags, :category, :offer_code).any?(&:present?) ||
        (params[:taxonomy].present? && params.values_at(:sort, :min_price, :max_price, :rating, :filetypes).any?(&:present?))
    end

    def taxonomy
      @taxonomy ||= Taxonomy.find_by_path(params[:taxonomy].split("/")) if params[:taxonomy].present?
    end

    def prepare_discover_page
      set_meta_tag(tag_name: "base", target: "_parent") unless user_signed_in?

      set_meta_tag(property: "og:title", content: "Gumroad")
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:site_name", content: "Gumroad")
      set_meta_tag(tag_name: "link", rel: "canonical", href: Discover::CanonicalUrlPresenter.canonical_url(params), head_key: "canonical")

      if !params[:taxonomy].present? && !params[:query].present? && params[:tags].present?
        presenter = Discover::TagPageMetaPresenter.new(params[:tags], @search_results[:total])
        set_meta_tag(title: "#{presenter.title} | Gumroad")
        set_meta_tag(name: "description", content: presenter.meta_description)
        set_meta_tag(property: "og:description", content: presenter.meta_description)
      else
        description = "Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs."
        set_meta_tag(name: "description", content: description)
        set_meta_tag(property: "og:description", content: description)
      end
    end

    def black_friday_feature_active?
      Feature.active?(:offer_codes_search) || (params[:feature_key].present? && ActiveSupport::SecurityUtils.secure_compare(params[:feature_key].to_s, ENV["SECRET_FEATURE_KEY"].to_s))
    end
end
