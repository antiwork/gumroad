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

    # The partner's creators, narrowed to one when `external_user_id` is given.
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
      search_params.merge(user_id: user_ids, is_alive_on_profile: true, exclude_ids: product_ids_hidden_from_profile(user_ids))
    end

    # A seller with saved profile sections shows only the products in their product grids and
    # featured product sections. A seller without saved sections shows every live product
    # (ProfileSectionsPresenter.default_products_section_available?).
    def product_ids_hidden_from_profile(user_ids)
      sections_by_seller_id = SellerProfileSection.on_profile.where(seller_id: user_ids).group_by(&:seller_id)
      return [] if sections_by_seller_id.empty?

      Link.where(user_id: sections_by_seller_id.keys).alive.not_archived.pluck(:id, :user_id).filter_map do |product_id, seller_id|
        product_id unless shown_on_profile?(product_id, sections_by_seller_id[seller_id])
      end
    end

    def shown_on_profile?(product_id, sections)
      sections.any? do |section|
        case section
        when SellerProfileProductsSection then section.shown_products.include?(product_id)
        when SellerProfileFeaturedProductSection then section.featured_product_id == product_id
        end
      end
    end

    def render_bad_request(message)
      render json: { success: false, message: }, status: :bad_request
    end
end
