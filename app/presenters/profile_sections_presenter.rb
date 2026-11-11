# frozen_string_literal: true

class ProfileSectionsPresenter
  include SearchProducts

  CACHE_KEY_PREFIX = "profile-sections"

  # Identifier for the "default products section": a virtual (never saved to the database)
  # products section that the public profile shows when a creator has published products but
  # hasn't set up any profile sections yet. Without it, new creators' profiles showed only an
  # email signup box even though they had products for sale. The frontend passes this id back
  # as section_id when it fetches more results, so LinksController#search recognizes it too.
  DEFAULT_PRODUCTS_SECTION_ID = "default-products"
  DEFAULT_PRODUCTS_SECTION_TYPE = "SellerProfileProductsSection"
  DEFAULT_PRODUCTS_TAB_NAME = "Products"

  CACHE_EXPIRES_IN = 10.minutes
  # A cold entry costs ~130 Elasticsearch searches for a large catalog. A visitor opening many of
  # one seller's product links at once used to run that on every request and queue the search
  # thread pool for ~20s, so only one request per key rebuilds while the rest wait for its write.
  BUILD_LOCK_TTL = 30.seconds
  BUILD_WAIT_TIMEOUT = 25.seconds
  BUILD_WAIT_INTERVAL = 0.1.seconds

  def self.default_products_section_available?(seller:, sections:)
    sections.empty? && seller.products.alive.not_archived.exists?
  end

  # seller is the owner of the section
  # pundit_user.seller is the selected seller for the logged-in user (pundit_user.user) - which may be different from seller
  def initialize(seller:, query:)
    @seller = seller
    @query = query
  end

  # `omit_product` drops that product from every products section (the product-page storefront
  # catalog passes the product the buyer is already viewing) and keeps `total` consistent with
  # the omission.
  def props(request:, pundit_user:, seller_custom_domain_url:, editing: pundit_user.seller == seller, include_default_products_section: false, omit_product: nil)
    sections = query.to_a
    # Load every card product for every section in one query up front. Loading them section by
    # section ran ~20 queries per section, so a 65-section storefront catalog cost ~1,200 queries
    # and ~2s on every product page view (gp#4526).
    section_cache = cached_sections
    if normalize_search_param_values!(request.query_parameters.slice(*VISITOR_SEARCH_PARAMS)).blank?
      preload_card_products(section_cache.flat_map { _1.dig(:search_results, :products) || [] })
    end

    props = {
      currency_code: pundit_user.user&.currency_type || Currency::USD,
      # Use the flag scope + `exists?` so this runs as `SELECT 1 ... LIMIT 1` in SQL.
      # The previous `.any?(&:display_product_reviews?)` loaded the seller's entire
      # alive catalog (full rows) into Ruby just to compute this one boolean, which
      # took multiple seconds for large-catalog sellers.
      show_ratings_filter: seller.links.alive.display_product_reviews.exists?,
      creator_profile: ProfilePresenter.new(seller:, pundit_user:).creator_profile,
      sections: section_cache.map do |props|
        section_props(sections.find { _1.external_id == props[:id] }, cached_props: props, request:, pundit_user:, seller_custom_domain_url:, editing:, omit_product:)
      end
    }
    # New creators who haven't customized their profile yet get a virtual products section so
    # visitors see what's for sale instead of just an email signup box. It only appears on the
    # public page (never in the profile editor, so `editing` must be false), only when the
    # creator has no saved sections, and only when they have products to show. The moment they
    # save a real section in the editor, their own layout takes over.
    if include_default_products_section &&
       !editing &&
       self.class.default_products_section_available?(seller:, sections:)
      default_section = cached_default_products_section
      props[:sections] = [section_props(nil, cached_props: default_section, request:, pundit_user:, seller_custom_domain_url:, editing: false, omit_product:)]
    end
    if editing
      props[:products] = seller.products.alive.not_archived.select(:id, :name).map { { id: ObfuscateIds.encrypt(_1.id), name: _1.name } }
      props[:posts] = visible_posts
      props[:wishlist_options] = seller.wishlists.alive.map { { id: _1.external_id, name: _1.name } }
    end
    props
  end

  def cached_sections
    sections_cache_key = query.cache_key_with_version
    cache_key = "#{CACHE_KEY_PREFIX}_#{REVISION}-#{products_cache_key}-#{sections_cache_key}"
    fetch_single_flight(cache_key) do
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

    # Computing this cache key runs a SQL query (count + max updated_at over the seller's
    # products), and both `cached_sections` and `cached_default_products_section` need it on the
    # same request - memoize so we only hit the database once per presenter instance.
    def products_cache_key
      @products_cache_key ||= seller.products.cache_key_with_version
    end

    # Rails.cache.fetch lets every concurrent miss rebuild. The builder writes the value before it
    # releases the lock, so a waiter that sees the lock gone finds the entry. If the holder dies or
    # is slow, a waiter builds after BUILD_WAIT_TIMEOUT rather than failing the page. One plain
    # read up front keeps the cache hit/miss metric at one event per request.
    def fetch_single_flight(cache_key, &build)
      cached = Rails.cache.read(cache_key)
      return cached unless cached.nil?

      lock_key = "#{cache_key}-build-lock"
      if shared_cache { Rails.cache.write(lock_key, true, unless_exist: true, expires_in: BUILD_LOCK_TTL) }
        begin
          # Another request may have finished between our miss and taking the lock. `exist?` keeps the
          # usual cold path to one read (the hit/miss metric counts reads), and the entry can still
          # expire before the read, so an empty read falls through to building.
          if shared_cache { Rails.cache.exist?(cache_key) }
            cached = shared_cache { Rails.cache.read(cache_key) }
            return cached unless cached.nil?
          end

          build_and_write(cache_key, &build)
        ensure
          shared_cache { Rails.cache.delete(lock_key) }
        end
      else
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + BUILD_WAIT_TIMEOUT
        while shared_cache { Rails.cache.exist?(lock_key) } && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
          sleep BUILD_WAIT_INTERVAL
        end
        shared_cache { Rails.cache.read(cache_key) } || build_and_write(cache_key, &build)
      end
    end

    def build_and_write(cache_key)
      yield.tap { |value| Rails.cache.write(cache_key, value, expires_in: CACHE_EXPIRES_IN) }
    end

    # The memcached store keeps a per-request copy of everything it reads, misses included, so a
    # poll would keep seeing the first answer. Reads and lock operations here must reach memcached.
    def shared_cache(&block)
      return yield unless Rails.cache.respond_to?(:bypass_local_cache, true)

      Rails.cache.send(:bypass_local_cache, &block)
    end

    # Builds the cacheable data for the virtual default products section after the shared
    # availability check above. Cached with the same 10-minute window as saved sections; the cache
    # key includes the products' cache version so publishing, archiving, or deleting a product
    # refreshes it.
    def cached_default_products_section
      cache_key = "#{CACHE_KEY_PREFIX}_default_#{REVISION}-#{products_cache_key}"
      fetch_single_flight(cache_key) do
        {
          id: DEFAULT_PRODUCTS_SECTION_ID,
          header: nil,
          type: DEFAULT_PRODUCTS_SECTION_TYPE,
          # Match what a freshly added products section would use: no filter sidebar, and the
          # page-layout sort (which, with no saved ordering, falls back to newest first).
          show_filters: false,
          default_product_sort: ProductSortKey::PAGE_LAYOUT,
          search_results: section_search_results(nil),
        }
      end
    end

    # Visitor-settable search filters. This reads the RAW query string, which never went through
    # format_search_params!, so anything not listed here reaches Link.search_options unsanitised —
    # including `search`, whose nested form is an arbitrary ES clause that can range-probe indexed
    # revenue fields, and `curated_product_ids`, which the controller decrypts before use.
    VISITOR_SEARCH_PARAMS = %i[query tags filetypes min_price max_price rating sort from size recommended_by].freeze

    def card_products_scope
      Link.includes(ProductPresenter::ASSOCIATIONS_FOR_CARD)
          .includes(
            { variant_categories_alive: :alive_variants },
            { bundle_products: { product: [:tiers, { variant_categories_alive: :alive_variants }], variant: [] } }
          )
    end

    # Cached section props store product ids as strings; key by integer id.
    def preload_card_products(ids)
      @card_products ||= {}
      missing = ids.map(&:to_i).uniq - @card_products.keys
      card_products_scope.where(id: missing).each { @card_products[_1.id] = _1 } if missing.any?
    end

    # Same contract as `find(ids)`: returns products in `ids` order and raises if one is missing.
    def card_products(ids)
      preload_card_products(ids)
      return card_products_scope.find(ids) if ids.any? { !@card_products.key?(_1.to_i) }
      ids.map { @card_products.fetch(_1.to_i) }
    end

    def section_props(section, cached_props:, request:, pundit_user:, seller_custom_domain_url:, editing:, omit_product: nil)
      params = normalize_search_param_values!(request.query_parameters.slice(*VISITOR_SEARCH_PARAMS))
      # `editing` selects the owner/editing payload shape. Product visibility (hiding sold-out
      # products) instead follows the real viewer, so the seller still sees every product on their
      # own public profile even though it renders the visitor shape.
      viewer_is_owner = pundit_user.seller == seller
      if editing
        cached_props.merge!(
          {
            hide_header: section.hide_header?,
            header: section.header || "",
          }
        )
      end

      case cached_props[:type]
      when "SellerProfileProductsSection"
        if editing
          cached_props.merge!(
            {
              shown_products: section.shown_products.map { ObfuscateIds.encrypt(_1) },
              add_new_products: section.add_new_products,
            }
          )
        end
        cached_props[:search_results] = section_search_results(section, params:) if params.present?
        products = card_products(cached_props[:search_results][:products])
        if omit_product
          before = products.size
          products = products.reject { |product| product.id == omit_product.id }
          if before > products.size
            cached_props[:search_results][:total] -= before - products.size
          elsif omit_product_in_search_total?(section, omit_product)
            # The product sits beyond the fetched page: `exclude_ids` pagination will never
            # return it, so the total must shrink here or the grid keeps requesting an empty
            # final page.
            cached_props[:search_results][:total] -= 1
          end
          cached_props[:exclude_ids] = [omit_product.external_id]
        end
        if !viewer_is_owner
          filtered_count = products.count { |product| product.hide_sold_out_variants? && product.remaining_for_sale_count == 0 }
          products = products.reject { |product| product.hide_sold_out_variants? && product.remaining_for_sale_count == 0 }
          cached_props[:search_results][:total] -= filtered_count
        end
        cached_props[:search_results][:products] = products.map do |product|
          ProductPresenter.card_for_web(product:, request:, recommended_by: params[:recommended_by], target: Product::Layout::PROFILE, show_seller: false, compute_description: false, compute_inventory: false)
        end
      when "SellerProfilePostsSection"
        if editing
          cached_props.merge!({ shown_posts: visible_posts(section:).pluck(:id), add_new_posts: section.add_new_posts })
        else
          cached_props[:posts] = visible_posts(section:)
        end
      when "SellerProfileFeaturedProductSection"
        unless editing
          featured_product_id = cached_props.delete(:featured_product_id)
          # Scope to alive products: an orphaned reference (deleted/soft-deleted/banned
          # product) is treated as "no featured product" instead of crashing on nil.
          featured_product = featured_product_id.present? ? seller.products.alive.find_by_external_id(featured_product_id) : nil
          cached_props.merge!(
            {
              props: featured_product.present? ?
                       ProductPresenter.new(product: featured_product, pundit_user:, request:).product_props(seller_custom_domain_url:) :
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

    # Mirrors the section's ES query so we only shrink the total when the search counted the
    # omitted product. No sold-out check: ES totals include sold-out products, so a sold-out
    # omitted product beyond the fetched page must still shrink the total.
    def omit_product_in_search_total?(section, omit_product)
      return false unless omit_product.alive? && !omit_product.archived?
      return omit_product.user_id == seller.id if section.nil?

      section.shown_products.include?(omit_product.id)
    end

    def section_search_results(section, params: {})
      search_results = search_products(
        params.merge(
          {
            # `section` is nil for the virtual default products section, which has no saved
            # sort preference - fall back to page-layout (effectively newest first).
            sort: params[:sort] || section&.default_product_sort || ProductSortKey::PAGE_LAYOUT,
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
      # Posts published on the same day (bulk imports, or anything that sets
      # published_at to a date rather than a timestamp) tie on published_at, and
      # a bare ORDER BY published_at leaves MySQL free to break that tie however
      # the chosen access path happens to return rows. That makes the profile
      # editor's saved shown_posts order depend on which index the planner picks,
      # which is not something callers should have to think about. Tie-break on
      # id so the order is stable regardless of the plan, matching what
      # CustomerPresenter#missed_posts already does for the same reason.
      query = seller.installments.visible_on_profile
                                 .order(published_at: :desc, id: :asc)
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
