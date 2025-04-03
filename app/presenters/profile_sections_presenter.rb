# frozen_string_literal: true

class ProfileSectionsPresenter
  include SearchProducts

  CACHE_KEY_PREFIX = "profile-sections"

  # seller is the owner of the section
  # pundit_user.seller is the selected seller for the logged-in user (pundit_user.user) - which may be different from seller
  def initialize(seller:, query:)
    @seller = seller
    @query = query
  end

  def props(request:, pundit_user:, seller_custom_domain_url:)
    sections = query.to_a

    props = {
      currency_code: pundit_user.user&.currency_type || Currency::USD,
      show_ratings_filter: seller.links.alive.any?(&:display_product_reviews?),
      creator_profile: ProfilePresenter.new(seller:, pundit_user:).creator_profile,
      sections: cached_sections.map do |props|
        section_props(sections.find { _1.external_id == props[:id] }, cached_props: props, request:, pundit_user:, seller_custom_domain_url:)
      end
    }
    if pundit_user.seller == seller
      props[:products] = seller.products.alive.not_archived.select(:id, :name).map { { id: ObfuscateIds.encrypt(_1.id), name: _1.name } }
      props[:posts] = visible_posts
      props[:wishlist_options] = seller.wishlists.alive.map { { id: _1.external_id, name: _1.name } }
    end
    props
  end

  def cached_sections
    products_cache_key = seller.products.cache_key_with_version
    sections_cache_key = query.cache_key_with_version
    cache_key = "#{CACHE_KEY_PREFIX}_#{REVISION}-#{products_cache_key}-#{sections_cache_key}"
    Rails.cache.fetch(cache_key, expires_in: 10.minutes) do
      query.map do |section|
        data = {
          id: section.external_id,
          header: section.hide_header? ? nil : section.header,
          type: section.type,
        }

        case section
        when SellerProfileProductsSection
          data.merge!(
            {
              show_filters: section.show_filters,
              default_product_sort: section.default_product_sort,
              search_results: section_search_results(section),
            }
          )
        when SellerProfileFeaturedProductSection
          data.merge!({ featured_product_id: ObfuscateIds.encrypt(section.featured_product_id) }) if section.featured_product_id.present?
        when SellerProfileRichTextSection
          data.merge!({ text: section.text })
        when SellerProfileSubscribeSection
          data.merge!({ button_label: section.button_label })
        when SellerProfileWishlistsSection
          data.merge!({ shown_wishlists: section.shown_wishlists.map { ObfuscateIds.encrypt(_1) } })
        end
        data
      end
    end
  end

  private
    attr_reader :seller, :query

    def section_props(section, cached_props:, request:, pundit_user:, seller_custom_domain_url:)
      is_owner = pundit_user.seller == seller
      params = request.query_parameters
      if is_owner
        cached_props.merge!(
          {
            hide_header: section.hide_header?,
            header: section.header || "",
          }
        )
      end

      case cached_props[:type]
      when "SellerProfileProductsSection"
        if is_owner
          cached_props.merge!(
            {
              shown_products: section.shown_products.map { ObfuscateIds.encrypt(_1) },
              add_new_products: section.add_new_products,
            }
          )
        end
        cached_props[:search_results] = section_search_results(section, params:) if params.present?
        cached_props[:search_results][:products] = Link.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD).find(cached_props[:search_results][:products]).map do |product|
          ProductPresenter.card_for_web(product:, request:, recommended_by: params[:recommended_by], target: Product::Layout::PROFILE, show_seller: false)
        end
      when "SellerProfilePostsSection"
        if is_owner
          cached_props.merge!({ shown_posts: visible_posts(section:).pluck(:id) })
        else
          cached_props[:posts] = visible_posts(section:)
        end
      when "SellerProfileFeaturedProductSection"
        unless is_owner
          cached_props.merge!(
            {
              props: cached_props[:featured_product_id].present? ?
                       ProductPresenter.new(product: seller.products.find_by_external_id(cached_props.delete(:featured_product_id)), pundit_user:, request:).product_props(seller_custom_domain_url:) :
                       nil,
            }
          )
        end
      when "SellerProfileWishlistsSection"
        cached_props[:wishlists] = WishlistPresenter
          .cards_props(wishlists: Wishlist.alive.where(id: section.shown_wishlists), pundit_user:, layout: Product::Layout::PROFILE)
          .sort_by { |wishlist| cached_props[:shown_wishlists].index(wishlist[:id]) }
      end
      cached_props
    end

    def section_search_results(section, params: {})
      search_results = search_products(
        params.merge(
          {
            sort: params[:sort] || section.default_product_sort,
            section:,
            is_alive_on_profile: true,
            user_id: seller.id,
          }
        )
      )
      search_results[:products] = search_results[:products].ids
      search_results
    end

    def visible_posts(section: nil)
      query = seller.installments.visible_on_profile
                                 .order(published_at: :desc)
                                 .page_with_kaminari(0)
                                 .per(999)
      query = query.where(id: section.shown_posts) if section

      query.map do |post|
        {
          id: post.external_id,
          name: post.name,
          slug: post.slug,
          published_at: post.published_at,
        }
      end
    end
end
