# frozen_string_literal: true

class Api::Internal::Admin::ProductsController < Api::Internal::Admin::BaseController
  include Pagy::Backend

  DEFAULT_PER_PAGE = Admin::Users::ListPaginatedProducts::PRODUCTS_PER_PAGE
  MAX_PER_PAGE = 100
  private_constant :DEFAULT_PER_PAGE, :MAX_PER_PAGE

  def list
    return render json: { success: false, message: "email is required" }, status: :bad_request if params[:email].blank?

    user = User.by_email(params[:email]).first
    return render json: { success: false, message: "User not found" }, status: :not_found if user.blank?

    products = user.products
      .includes(:product_files, :display_asset_previews, :thumbnail_alive)
      .order(Admin::Users::ListPaginatedProducts::PRODUCTS_ORDER)

    pagination, paginated = pagy(products, page: params[:page], limit: per_page)

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
    def per_page
      requested = params[:per_page].to_i
      return DEFAULT_PER_PAGE unless requested.positive?

      [requested, MAX_PER_PAGE].min
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
        files: product.product_files.in_order.map { serialize_file(_1) }
      }
    end

    def serialize_file(file)
      {
        id: file.external_id,
        display_name: file.name_displayable,
        file_name: file.s3_filename,
        extension: file.s3_display_extension,
        filegroup: file.filegroup,
        file_size: file.size,
        created_at: file.created_at.iso8601,
        deleted_at: file.deleted_at&.iso8601
      }
    end
end
