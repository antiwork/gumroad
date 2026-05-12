# frozen_string_literal: true

class Api::Internal::Admin::ProductsController < Api::Internal::Admin::BaseController
  include Pagy::Backend

  DEFAULT_PER_PAGE = Admin::Users::ListPaginatedProducts::PRODUCTS_PER_PAGE
  MAX_PER_PAGE = 100
  SELLER_LOOKUP_BAD_REQUEST_MESSAGE = "email or external_id is required"
  RECENT_CHARGEBACK_WINDOW_DAYS = 90
  NON_GLOBAL_AFFILIATE_TYPES = [DirectAffiliate.name, Collaborator.name].freeze
  private_constant :DEFAULT_PER_PAGE, :MAX_PER_PAGE, :SELLER_LOOKUP_BAD_REQUEST_MESSAGE,
                   :RECENT_CHARGEBACK_WINDOW_DAYS, :NON_GLOBAL_AFFILIATE_TYPES

  def index
    if params[:email].blank? && params[:external_id].blank?
      return render json: { success: false, message: SELLER_LOOKUP_BAD_REQUEST_MESSAGE }, status: :bad_request
    end

    user = find_seller_or_render
    return unless user

    products = user.products
      .includes(:product_files, :display_asset_previews, :taxonomy, product_affiliates: { affiliate: :affiliate_user })
      .order(Admin::Users::ListPaginatedProducts::PRODUCTS_ORDER)

    pagination, paginated = pagy(products, page: requested_page, limit: per_page, overflow: :empty_page)

    render json: {
      success: true,
      products: paginated.map { serialize_product(_1) },
      pagination: PagyPresenter.new(pagination).metadata
    }
  end

  def show
    product = Link.find_by_external_id(params[:id])
    return render json: { success: false, message: "Product not found" }, status: :not_found if product.blank?

    render json: { success: true, product: serialize_product(product, with_fraud_context: true) }
  end

  private
    def find_seller_or_render
      user = if params[:external_id].present?
        User.find_by(external_id: params[:external_id])
      else
        User.by_email(params[:email]).first
      end
      return user if user.present?

      render json: { success: false, message: "User not found" }, status: :not_found
      nil
    end

    def per_page
      requested = params[:per_page].to_i
      return DEFAULT_PER_PAGE unless requested.positive?

      [requested, MAX_PER_PAGE].min
    end

    def requested_page
      [params[:page].to_i, 1].max
    end

    def serialize_product(product, with_fraud_context: false)
      payload = {
        id: product.external_id,
        name: product.name,
        description: product.description,
        price_cents: product.price_cents,
        currency_code: product.price_currency_type,
        permalink: product.unique_permalink,
        long_url: product.long_url,
        preview_url: product.preview_url,
        created_at: product.created_at.iso8601,
        deleted_at: product.deleted_at&.iso8601,
        banned_at: product.banned_at&.iso8601,
        purchase_disabled_at: product.purchase_disabled_at&.iso8601,
        alive: product.alive?,
        is_adult: product.is_adult?,
        bad_card_counter: product.bad_card_counter,
        taxonomy: serialize_product_taxonomy(product.taxonomy),
        seller: {
          id: product.user&.external_id,
          email: product.user&.email
        },
        affiliates: serialize_product_affiliates(product),
        files: product.product_files.sort_by { |f| [f.position.nil? ? 0 : 1, f.position.to_i, f.id] }.map { serialize_file(_1) }
      }
      payload[:recent_chargeback_rate] = recent_chargeback_rate(product) if with_fraud_context
      payload
    end

    def serialize_product_taxonomy(taxonomy)
      return nil if taxonomy.nil?

      {
        id: taxonomy.id.to_s,
        slug: taxonomy.slug,
        ancestry_path: taxonomy.ancestry_path,
      }
    end

    def serialize_product_affiliates(product)
      affiliates = product.product_affiliates.to_a.select do |pa|
        NON_GLOBAL_AFFILIATE_TYPES.include?(pa.affiliate&.type)
      end
      affiliates.sort_by(&:id).map { serialize_product_affiliate(_1) }
    end

    def serialize_product_affiliate(product_affiliate)
      affiliate = product_affiliate.affiliate
      basis_points = product_affiliate.affiliate_basis_points || affiliate.affiliate_basis_points
      affiliate_user = affiliate.affiliate_user
      {
        id: affiliate.external_id,
        type: affiliate.type,
        affiliate_user: affiliate_user && {
          id: affiliate_user.external_id,
          email: affiliate_user.email,
        },
        basis_points: basis_points,
        destination_url: product_affiliate.destination_url,
      }
    end

    def recent_chargeback_rate(product)
      window = RECENT_CHARGEBACK_WINDOW_DAYS.days.ago
      successful_count = Purchase.successful.where(link_id: product.id).where("purchases.created_at >= ?", window).count
      payload = { window_days: RECENT_CHARGEBACK_WINDOW_DAYS, successful_count:, chargedback_count: 0, rate: nil }
      return payload if successful_count.zero?

      chargedback_count = Purchase.chargedback.where(link_id: product.id).where("purchases.created_at >= ?", window).count
      payload.merge(chargedback_count:, rate: (chargedback_count.to_f / successful_count).round(4))
    end

    def serialize_file(file)
      {
        id: file.external_id,
        display_name: file.name_displayable,
        file_name: file.external_link? ? file.url : file.s3_filename,
        extension: file.display_extension,
        filegroup: file.filegroup,
        file_size: file.size,
        created_at: file.created_at.iso8601,
        deleted_at: file.deleted_at&.iso8601
      }
    end
end
