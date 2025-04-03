# frozen_string_literal: true

class Api::V2::LinksController < Api::V2::BaseController
  before_action(only: [:show, :index]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :disable, :enable, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :check_types_of_file_objects, only: [:update, :create]
  before_action :set_link_id_to_id, only: [:show, :update, :disable, :enable, :destroy]
  before_action :fetch_product, only: [:show, :update, :disable, :enable, :destroy]

  def index
    products = current_resource_owner.products.visible.includes(
      :preorder_link, :tags, :taxonomy,
      variant_categories_alive: [:alive_variants],
    ).order(created_at: :desc)

    as_json_options = {
      api_scopes: doorkeeper_token.scopes,
      preloaded_ppp_factors: PurchasingPowerParityService.new.get_all_countries_factors(current_resource_owner)
    }

    products_as_json = products.as_json(as_json_options)

    render json: { success: true, products: products_as_json }
  end

  def create
    e404
  end

  def show
    success_with_product(@product)
  end

  def update
    e404
  end

  def disable
    return success_with_product(@product) if @product.unpublish!

    error_with_product(@product)
  end

  def enable
    return error_with_product(@product) unless @product.validate_product_price_against_all_offer_codes?

    begin
      @product.publish!
    rescue Link::LinkInvalid
      return error_with_product(@product)
    rescue => e
      Bugsnag.notify(e)
      return render_response(false, message: "Something broke. We're looking into what happened. Sorry about this!")
    end

    success_with_product(@product)
  end

  def destroy
    success_with_product if @product.delete!
  end

  private
    def success_with_product(product = nil)
      success_with_object(:product, product)
    end

    def error_with_product(product = nil)
      error_with_object(:product, product)
    end

    def check_types_of_file_objects
      return if params[:file].class != String && params[:preview].class != String

      render_response(false, message: "You entered the name of the file to be uploaded incorrectly. Please refer to " \
                                      "https://gumroad.com/api#methods for the correct syntax.")
    end

    def set_link_id_to_id
      params[:link_id] = params[:id]
    end
end
