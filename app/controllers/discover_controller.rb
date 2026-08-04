# frozen_string_literal: true

class DiscoverController < ApplicationController
  RECOMMENDED_PRODUCTS_COUNT = 8
  INITIAL_PRODUCTS_COUNT = 36

  include ActionView::Helpers::NumberHelper, RecommendationType, CreateDiscoverSearch,
          DiscoverCuratedProducts, SearchProducts, AffiliateCookie

  layout "inertia", only: [:index]

  before_action :set_affiliate_cookie, only: [:index]

  def index
    if autocomplete_only_request?
      create_discover_search!(query: params[:query], autocomplete: true) if params[:query].present?
      return render inertia: "Discover/Index", props: {
        autocomplete_results: autocomplete_results_data
      }
    end

    format_search_params!

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

    search_results = search_products(params)
    search_results[:products] = search_results[:products].includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).map do |product|
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

    prepare_discover_page(search_results:)
    prepare_category_seo(search_results:)

    curated_product_ids = curated_products.map { _1.product.external_id }
    render inertia: "Discover/Index", props: {
      search_results:,
      currency_code: logged_in_user&.currency_type || "usd",
      taxonomies_for_nav:,
      curated_product_ids:,
      search_offset: params[:from] || 0,
      show_black_friday_hero: -> { black_friday_feature_active? },
      is_black_friday_page: params[:offer_code] == SearchProducts::BLACK_FRIDAY_CODE,
      black_friday_offer_code: SearchProducts::BLACK_FRIDAY_CODE,
      black_friday_stats: -> { black_friday_feature_active? ? BlackFridayStatsService.fetch_stats : nil },
      recommended_products: InertiaRails.defer { recommendations },
      recommended_wishlists: InertiaRails.defer { recommended_wishlists_data },
    }
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
      params.values_at(:query, :tags, :category, :offer_code, :taxonomy_attribute_filters).any?(&:present?) ||
        (params[:taxonomy].present? && params.values_at(:sort, :min_price, :max_price, :rating, :filetypes).any?(&:present?))
    end

    def taxonomy
      @taxonomy ||= Taxonomy.find_by_path(params[:taxonomy].split("/")) if params[:taxonomy].present?
    end

    def prepare_discover_page(search_results:)
      set_meta_tag(tag_name: "base", target: "_parent") unless user_signed_in?

      title_parts = []
      if params[:query].present?
        title_parts << "Search results for \"#{params[:query]}\""
      elsif params[:tags].present? && !params[:taxonomy].present?
        presenter = Discover::TagPageMetaPresenter.new(params[:tags], search_results[:total])
        title_parts << presenter.title
      elsif params[:tags].present?
        tags = params[:tags].is_a?(Array) ? params[:tags] : params[:tags].split(",")
        title_parts << tags.map { |tag| tag.strip.gsub(/[-\s]+/, " ") }.join(", ")
      end
      if params[:taxonomy].present?
        labels = params[:taxonomy].split("/").map { |slug| Discover::TaxonomyPresenter::TAXONOMY_LABELS[slug] || slug }
        title_parts << labels.join(" » ")
      end
      title_parts << "Gumroad"
      set_meta_tag(title: title_parts.join(" | "))

      set_meta_tag(property: "og:title", content: "Gumroad")
      set_meta_tag(property: "og:type", content: "website")
      set_meta_tag(property: "og:site_name", content: "Gumroad")
      set_meta_tag(tag_name: "link", rel: "canonical", href: Discover::CanonicalUrlPresenter.canonical_url(params), head_key: "canonical")

      if !params[:taxonomy].present? && !params[:query].present? && params[:tags].present?
        presenter = Discover::TagPageMetaPresenter.new(params[:tags], search_results[:total])
        set_meta_tag(name: "description", content: presenter.meta_description)
        set_meta_tag(property: "og:description", content: presenter.meta_description)
      else
        description = "Browse over 1.6 million free and premium digital products in education, tech, design, and more categories from Gumroad creators and online entrepreneurs."
        set_meta_tag(name: "description", content: description)
        set_meta_tag(property: "og:description", content: description)
      end
    end

    # Category/subcategory pages (taxonomy present, no query/tags) are landing pages for
    # organic search, so they get a dedicated title/description plus BreadcrumbList and
    # ItemList JSON-LD in the server-rendered head. Skipped for filtered/search views to
    # keep the canonical page the only indexable variant.
    def category_seo_page?
      taxonomy.present? && params.values_at(:query, :tags).all?(&:blank?)
    end

    def prepare_category_seo(search_results:)
      if taxonomy.blank? && params.values_at(:query, :tags).all?(&:blank?)
        @discover_category_links = Discover::CategoryPagePresenter.root_category_links
        return
      end
      return unless category_seo_page?

      presenter = Discover::CategoryPagePresenter.new(taxonomy_path: params[:taxonomy], taxonomy:, search_results:)

      set_meta_tag(title: presenter.title)
      set_meta_tag(property: "og:title", content: presenter.title)
      set_meta_tag(name: "description", content: presenter.meta_description)
      set_meta_tag(property: "og:description", content: presenter.meta_description)

      set_meta_tag(tag_name: "script", type: "application/ld+json", inner_content: presenter.breadcrumb_list_json_ld, head_key: "breadcrumb-list-json-ld")
      item_list = presenter.item_list_json_ld
      set_meta_tag(tag_name: "script", type: "application/ld+json", inner_content: item_list, head_key: "item-list-json-ld") if item_list

      @discover_category_links = presenter.subcategory_links
      @discover_pagination_links = pagination_links(search_results:)
    end

    # params[:from] (not the raw request query param) is the actual ES offset behind
    # search_results — index mutates it to RECOMMENDED_PRODUCTS_COUNT + 1 on the canonical
    # first page to skip products already shown in the recommendations strip, so pagination
    # math has to agree with that offset or "Next" repeats the recommended-strip products.
    # first_page suppresses a self-referencing "Previous" link on that mutated first page,
    # since the raw request has no `from` at all there.
    def pagination_links(search_results:)
      offset = params[:from].to_i
      first_page = request.query_parameters["from"].blank?
      links = []
      links << { label: "Previous page", href: UrlService.discover_full_path("/#{params[:taxonomy]}", { from: [offset - INITIAL_PRODUCTS_COUNT, 0].max.nonzero? }.compact) } if offset > 0 && !first_page
      links << { label: "Next page", href: UrlService.discover_full_path("/#{params[:taxonomy]}", from: offset + INITIAL_PRODUCTS_COUNT) } if search_results[:total].to_i > offset + INITIAL_PRODUCTS_COUNT
      links
    end

    def black_friday_feature_active?
      Feature.active?(:offer_codes_search) || (params[:feature_key].present? && ActiveSupport::SecurityUtils.secure_compare(params[:feature_key].to_s, ENV["SECRET_FEATURE_KEY"].to_s))
    end

    def recommended_wishlists_data
      wishlists = RecommendedWishlistsService.fetch(
        limit: 4,
        current_seller:,
        curated_product_ids: curated_products.map { _1.product.id },
        taxonomy_id: taxonomy&.id
      )

      WishlistPresenter.cards_props(
        wishlists:,
        pundit_user:,
        layout: Product::Layout::DISCOVER,
        recommended_by: RecommendationType::GUMROAD_DISCOVER_WISHLIST_RECOMMENDATION,
      )
    end

    def autocomplete_only_request?
      request.headers["X-Inertia-Partial-Data"] == "autocomplete_results"
    end

    def autocomplete_results_data
      Discover::AutocompletePresenter.new(
        query: params[:query],
        user: logged_in_user,
        browser_guid: cookies[:_gumroad_guid]
      ).props
    end
end
