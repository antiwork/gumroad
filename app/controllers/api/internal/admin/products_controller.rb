# frozen_string_literal: true

class Api::Internal::Admin::ProductsController < Api::Internal::Admin::BaseController
  include Pagy::Backend

  DEFAULT_PER_PAGE = Admin::Users::ListPaginatedProducts::PRODUCTS_PER_PAGE
  MAX_PER_PAGE = 100
  SELLER_LOOKUP_BAD_REQUEST_MESSAGE = "email or external_id is required"
  private_constant :DEFAULT_PER_PAGE, :MAX_PER_PAGE, :SELLER_LOOKUP_BAD_REQUEST_MESSAGE

  def index
    if params[:email].blank? && params[:external_id].blank?
      return render json: { success: false, message: SELLER_LOOKUP_BAD_REQUEST_MESSAGE }, status: :bad_request
    end

    user = find_seller_or_render
    return unless user

    products = user.products
      .includes(:product_files, :display_asset_previews)
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

    render json: { success: true, product: serialize_product(product) }
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

    def serialize_product(product)
      {
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
        alive: product.alive?,
        is_adult: product.is_adult?,
        seller: {
          id: product.user&.external_id,
          email: product.user&.email
        },
        files: product.product_files.sort_by { |f| [f.position.nil? ? 0 : 1, f.position.to_i, f.id] }.map { serialize_file(_1) }
      }
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
