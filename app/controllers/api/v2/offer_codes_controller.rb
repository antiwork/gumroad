# frozen_string_literal: true

class Api::V2::OfferCodesController < Api::V2::BaseController
  RESULTS_PER_PAGE = 10

  before_action only: [:index, :show] do
    if product_scoped?
      doorkeeper_authorize!(*Doorkeeper.configuration.public_api_read_scopes.concat([:view_public]))
    else
      doorkeeper_authorize! :view_sales, :edit_products
    end
  end
  before_action(only: [:create, :update, :destroy]) { doorkeeper_authorize! :edit_products }
  before_action :check_offer_code_params, only: [:create]
  before_action :fetch_product, if: :product_scoped?
  before_action :fetch_offer_code, only: %i[show update destroy]
  before_action :parse_validity_period, only: %i[create update]

  def index
    return success_with_object(:offer_codes, @product.product_and_universal_offer_codes) if @product

    codes = current_resource_owner.offer_codes.alive.order(created_at: :desc, id: :desc)
    if params.key?(:auto_apply)
      return error_400("auto_apply must be true or false.") unless params[:auto_apply].in?([true, false, "true", "false"])

      codes = codes.where(auto_apply: true_param?(:auto_apply))
    end
    if params[:page_key].present?
      return error_400("Invalid page_key.") unless params[:page_key].is_a?(String)

      begin
        created_at, id = decode_page_key(params[:page_key])
      rescue ArgumentError
        return error_400("Invalid page_key.")
      end
      codes = codes.where("created_at < ? OR (created_at = ? AND id < ?)", created_at, created_at, id)
    end
    page = codes.limit(RESULTS_PER_PAGE + 1).to_a
    additional = page.size > RESULTS_PER_PAGE ? pagination_info(page[RESULTS_PER_PAGE - 1]) : {}
    success_with_object(:offer_codes, page.first(RESULTS_PER_PAGE), additional)
  end

  def create
    universal = true_param?(:universal)
    auto_apply = true_param?(:auto_apply)
    offer_code = if params[:offer_type] == "percent"
      OfferCode.new(code: params[:name],
                    universal:,
                    amount_percentage: params[:amount_off].to_i,
                    max_purchase_count: params[:max_purchase_count],
                    auto_apply:,
                    sale_label: params[:sale_label],
                    minimum_amount_cents: params[:minimum_amount_cents].presence)
    else
      OfferCode.new(code: params[:name],
                    universal:,
                    amount_cents: params[:amount_cents].presence || params[:amount_off].presence,
                    max_purchase_count: params[:max_purchase_count],
                    minimum_amount_cents: params[:minimum_amount_cents].presence,
                    auto_apply:,
                    sale_label: params[:sale_label],
                    currency_type: @product.price_currency_type)
    end

    offer_code.assign_attributes(params.permit(:valid_at, :expires_at))
    offer_code.user = @product.user
    offer_code.products << @product unless universal
    offer_code.created_via_cli = true if request_from_cli?

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
    def product_scoped?
      request.path_parameters[:link_id].present?
    end

    def permitted_params
      permitted = params.permit(:max_purchase_count, :minimum_amount_cents, :auto_apply, :sale_label, :valid_at, :expires_at)
      permitted[:auto_apply] = true_param?(:auto_apply) if permitted.key?(:auto_apply)
      permitted
    end

    def parse_validity_period
      %i[valid_at expires_at].each do |key|
        next unless params.key?(key)

        value = params[key]
        if value.nil? || value == ""
          params[key] = nil
          next
        end

        # Time.new normalizes impossible days, 24:00, and leap seconds into different times.
        parts = Date._rfc3339(value)
        unless Date.valid_date?(parts[:year], parts[:mon], parts[:mday]) && (0..23).cover?(parts[:hour]) && (0..59).cover?(parts[:sec])
          raise ArgumentError
        end
        params[key] = Time.zone.rfc3339(value)
      rescue ArgumentError, TypeError
        render_response(false, message: "#{key} must be an RFC 3339 timestamp with a time zone, or null.")
        return
      end
    end

    # Only a JSON true or the documented "true" string counts: Rails' boolean cast reads any
    # string off its false list, such as "False" or "no", as true.
    def true_param?(key)
      params[key].in?([true, "true"])
    end

    def check_offer_code_params
      return if params[:amount_off].present? || params[:amount_cents].present?

      render_response(false, message: "You are missing required offer code parameters. Please refer to " \
                                      "https://gumroad.com/api#offer-codes for the correct parameters.")
    end

    def fetch_offer_code
      @offer_code = if @product
        @product.find_offer_code_by_external_id(params[:id])
      else
        current_resource_owner.offer_codes.alive.find_by_external_id(params[:id])
      end
      error_with_offer_code if @offer_code.nil?
    end

    def success_with_offer_code(offer_code = nil)
      success_with_object(:offer_code, offer_code)
    end

    def error_with_offer_code(offer_code = nil)
      error_with_object(:offer_code, offer_code)
    end
end
