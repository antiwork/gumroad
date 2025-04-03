# frozen_string_literal: true

class Api::V2::OfferCodesController < Api::V2::BaseController
  before_action(only: [:index, :show]) { doorkeeper_authorize!(*Doorkeeper.configuration.public_scopes.concat([:view_public])) }
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :check_offer_code_params, only: [:create]
  before_action :fetch_product
  before_action :fetch_offer_code, only: %i[show update destroy]

  def index
    offer_codes = @product.product_and_universal_offer_codes
    success_with_object(:offer_codes, offer_codes)
  end

  def create
    offer_code = if params[:offer_type] == "percent"
      OfferCode.new(code: params[:name],
                    universal: params[:universal] == "true",
                    amount_percentage: params[:amount_off].to_i,
                    max_purchase_count: params[:max_purchase_count])
    else
      OfferCode.new(code: params[:name],
                    universal: params[:universal] == "true",
                    amount_cents: params[:amount_cents].presence || params[:amount_off].presence,
                    max_purchase_count: params[:max_purchase_count],
                    currency_type: @product.price_currency_type)
    end

    offer_code.user = @product.user
    offer_code.products << @product unless params[:universal] == "true"

    if offer_code.save
      success_with_offer_code(offer_code)
    else
      error_with_creating_object(:offer_code, offer_code)
    end
  end

  def show
    success_with_offer_code(@offer_code)
  end

  def update
    if @offer_code.update(permitted_params)
      success_with_offer_code(@offer_code)
    else
      error_with_offer_code(@offer_code)
    end
  end

  def destroy
    if @offer_code.update(deleted_at: Time.current)
      success_with_offer_code
    else
      error_with_offer_code
    end
  end

  private
    def permitted_params
      params.permit(:max_purchase_count)
    end

    def check_offer_code_params
      return if params[:amount_off].present? || params[:amount_cents].present?

      render_response(false, message: "You are missing required offer code parameters. Please refer to " \
                                      "https://gumroad.com/api#offer-codes for the correct parameters.")
    end

    def fetch_offer_code
      @offer_code = @product.find_offer_code_by_external_id(params[:id])
      error_with_offer_code if @offer_code.nil?
    end

    def success_with_offer_code(offer_code = nil)
      success_with_object(:offer_code, offer_code)
    end

    def error_with_offer_code(offer_code = nil)
      error_with_object(:offer_code, offer_code)
    end
end
