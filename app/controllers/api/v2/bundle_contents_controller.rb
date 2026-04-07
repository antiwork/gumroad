# frozen_string_literal: true

class Api::V2::BundleContentsController < Api::V2::BaseController
  MAX_INTEGER = 2_147_483_647

  before_action { doorkeeper_authorize! :edit_products }
  before_action :fetch_product

  def update
    return render_response(false, message: "This product is not a bundle.") if @product.not_is_bundle?

    products = content_permitted_params
    return render_response(false, message: "Products must be an array.") if !products.is_a?(Array)

    products.each { |p| p[:quantity] = 1 if p[:quantity].nil? }

    if (error = validate_products(products))
      return render_response(false, message: error)
    end

    ActiveRecord::Base.transaction do
      @product.lock!
      Bundle::UpdateProductsService.new(bundle: @product, products:).perform
    end

    @product.reload
    success_with_object(:product, @product)
  rescue ActiveRecord::RecordNotFound
    render_response(false, message: "One or more products could not be found.")
  rescue ActiveRecord::RecordNotSaved, ActiveRecord::RecordInvalid => e
    error_message = e.record&.errors&.full_messages&.to_sentence.presence || e.message
    render_response(false, message: error_message)
  rescue Link::LinkInvalid => e
    render_response(false, message: e.message)
  end

  private
    def content_permitted_params
      params.permit(products: %i[product_id variant_id quantity position]).fetch(:products, [])
    end

    def validate_products(products)
      products.each do |p|
        qty = Integer(p[:quantity], exception: false)
        return "Quantity must be an integer greater than 0." if qty.nil? || qty < 1 || qty > MAX_INTEGER

        if p[:position].present?
          pos = Integer(p[:position], exception: false)
          return "Position must be a valid integer." if pos.nil? || pos > MAX_INTEGER
        end
      end
      nil
    end
end
