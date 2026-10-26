# frozen_string_literal: true

# Endpoints for partner applications. A partner authenticates as the application itself
# (OAuth client credentials with the partner_api scope), never as a seller, and only ever sees
# the sellers it brought over (PartnerCreator).
#
# The scope alone is not enough: any self-serve application can mint client-credentials tokens,
# so the application must also be flagged as a partner and be confidential (secret required).
class Api::V2::Partner::BaseController < Api::V2::BaseController
  include SearchProducts

  # log_method_use reads current_resource_owner, which a client-credentials token does not have.
  skip_after_action :log_method_use

  before_action { doorkeeper_authorize! :partner_api }
  before_action { require_oauth_scope! :partner_api }
  before_action :require_partner_application!

  # What remaining_for_sale_count reads, without the card associations.
  INVENTORY_ASSOCIATIONS = [
    :tiers,
    { variant_categories_alive: :alive_variants },
    { bundle_products: { product: [:tiers, { variant_categories_alive: :alive_variants }], variant: [] } },
  ].freeze
  SOLD_OUT_CACHE_TTL = 5.minutes

  SORT_KEYS = [
    ProductSortKey::BEST_SELLERS,
    ProductSortKey::NEWEST,
    ProductSortKey::HOT_AND_NEW,
    ProductSortKey::HIGHEST_RATED,
    ProductSortKey::MOST_REVIEWED,
  ].freeze

  private
    def current_partner_application
      @current_partner_application ||= OauthApplication.alive.find_by(id: doorkeeper_token.application_id)
    end

    def require_partner_application!
      application = current_partner_application
      return if doorkeeper_token.resource_owner_id.nil? && application&.is_partner? && application.confidential?

      render json: { success: false, message: "This endpoint is only available to partner applications." }, status: :forbidden
    end

    def partner_creators_in_scope
      creators = current_partner_application.partner_creators.alive.includes(:user)
      creators = creators.where(external_user_id: params[:external_user_id].to_s) if params[:external_user_id].present?
      creators
    end

    # Search filters shared by the partner product and creator endpoints, or nil when `category`
    # is not a category path from GET /v2/partner/categories. Products are limited to `creators` and to
    # what a logged-out visitor sees on their profiles: passing user_id skips Discover's own
    # visibility filters, so is_alive_on_profile is required here.
    def product_search_params(creators)
      search_params = normalize_search_param_values!(params.permit(:query, :min_price, :max_price, :tags, tags: []).to_h.symbolize_keys)

      if params[:category].present?
        category = Discover::TaxonomyPresenter.new.category_for_path(params[:category].to_s)
        return if category.nil?

        search_params.merge!(taxonomy_id: category[:id], include_taxonomy_descendants: true)
      end

      user_ids = creators.map(&:user_id)
      exclude_ids = product_ids_hidden_from_profile(user_ids) + sold_out_product_ids_hidden_from_visitors(user_ids)
      search_params.merge(user_id: user_ids, is_alive_on_profile: true, exclude_ids:)
    end

    # A seller with saved profile sections shows only the products in their product grids and
    # featured product sections. A seller without saved sections shows every live product
    # (ProfileSectionsPresenter.default_products_section_available?).
    def product_ids_hidden_from_profile(user_ids)
      shown_ids_by_seller_id = SellerProfileSection.on_profile.where(seller_id: user_ids).each_with_object({}) do |section, shown|
        ids = shown[section.seller_id] ||= Set.new
        case section
        when SellerProfileProductsSection then ids.merge(section.shown_products)
        when SellerProfileFeaturedProductSection then ids << section.featured_product_id
        end
      end
      return [] if shown_ids_by_seller_id.empty?

      Link.where(user_id: shown_ids_by_seller_id.keys).alive.not_archived.pluck(:id, :user_id).filter_map do |product_id, seller_id|
        product_id unless shown_ids_by_seller_id[seller_id].include?(product_id)
      end
    end

    # Visitors do not see a sold-out product whose seller hides sold-out items (ProfileSectionsPresenter).
    # The stock check reads each limited product's sales count, so the result is cached per seller
    # and a request scans only the sellers missing from the cache.
    def sold_out_product_ids_hidden_from_visitors(user_ids)
      keys = user_ids.index_by { "partner_api/hidden_sold_out_product_ids/#{_1}" }
      cached = Rails.cache.read_multi(*keys.keys)
      missing_user_ids = keys.except(*cached.keys).values
      if missing_user_ids.any?
        hidden_ids_by_user_id = missing_user_ids.index_with { [] }
        Link.where(user_id: missing_user_ids).alive.not_archived.hide_sold_out_variants.includes(INVENTORY_ASSOCIATIONS).find_each do |product|
          hidden_ids_by_user_id[product.user_id] << product.id if product.remaining_for_sale_count == 0
        end
        fresh = hidden_ids_by_user_id.transform_keys { "partner_api/hidden_sold_out_product_ids/#{_1}" }
        Rails.cache.write_multi(fresh, expires_in: SOLD_OUT_CACHE_TTL)
        cached.merge!(fresh)
      end
      cached.values.flatten
    end

    def render_bad_request(message)
      render json: { success: false, message: }, status: :bad_request
    end
end
