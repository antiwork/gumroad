# frozen_string_literal: true

class DollarStoreController < ApplicationController
  MAX_PRICE_DOLLARS = 1
  PAGE_SIZE = 36
  PRICE_MODES = %w[paid free_and_paid include_pwyw].freeze
  DEFAULT_PRICE_MODE = "free_and_paid"

  include RecommendationType, SearchProducts, AffiliateCookie

  layout "inertia"

  before_action :set_affiliate_cookie

  def index
    format_search_params!

    price_mode = PRICE_MODES.include?(params[:price_mode]) ? params[:price_mode] : DEFAULT_PRICE_MODE

    params[:max_price] = MAX_PRICE_DOLLARS
    params[:min_price] = 0.01 if price_mode == "paid"
    params[:sort] = ProductSortKey::RANDOM
    params[:random_seed] = random_seed
    params[:include_rated_as_adult] = logged_in_user&.show_nsfw_products?
    params[:size] = PAGE_SIZE

    if selected_taxonomy.present?
      params[:taxonomy_id] = selected_taxonomy.id
      params[:include_taxonomy_descendants] = true
    end

    search_results = search_products(params)
    search_results[:products] = search_results[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).map do |product|
      ProductPresenter.card_for_web(
        product:,
        request:,
        recommended_by: RecommendationType::GUMROAD_DISCOVER_RECOMMENDATION,
        target: Product::Layout::DISCOVER,
        compute_description: true
      )
    end

    set_meta_tag(title: "Dollar store | Gumroad")
    set_meta_tag(name: "description", content: "Discover Gumroad products you can buy for a dollar or less.")

    render inertia: "DollarStore", props: {
      search_results:,
      currency_code: logged_in_user&.currency_type || "usd",
      price_mode:,
      random_seed: params[:random_seed],
      search_offset: params[:from] || 0,
      taxonomies: Discover::TaxonomyPresenter.new.taxonomies_for_nav,
      selected_taxonomy_path: selected_taxonomy_path,
      selected_taxonomy_label: selected_taxonomy_label
    }
  end

  private
    def random_seed
      return params[:random_seed].to_i if params[:random_seed].present?
      session[:dollar_store_seed] ||= SecureRandom.random_number(2**31 - 1)
    end

    def selected_taxonomy
      return @selected_taxonomy if defined?(@selected_taxonomy)
      @selected_taxonomy = params[:taxonomy].present? ? Taxonomy.find_by_path(params[:taxonomy].split("/")) : nil
    end

    def selected_taxonomy_path
      return nil unless selected_taxonomy
      slugs = []
      node = selected_taxonomy
      while node
        slugs.unshift(node.slug)
        node = node.parent
      end
      slugs.join("/")
    end

    def selected_taxonomy_label
      return nil unless selected_taxonomy
      Discover::TaxonomyPresenter::TAXONOMY_LABELS[selected_taxonomy.slug] || selected_taxonomy.slug.titleize
    end
end
