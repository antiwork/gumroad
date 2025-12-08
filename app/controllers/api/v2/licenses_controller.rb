# frozen_string_literal: true

class Api::V2::LicensesController < Api::V2::BaseController
  before_action :log_params, only: [:verify]
  before_action :clean_params, only: [:verify]
  before_action(only: [:enable, :disable, :decrement_uses_count, :rotate]) { doorkeeper_authorize! :edit_products }
  before_action :fetch_valid_license
  before_action :validate_license_user, only: [:enable, :disable, :decrement_uses_count, :rotate]
  skip_before_action :verify_authenticity_token, only: [:verify]

  # Purchase values we want to include for license API responses
  WHITELIST_PURCHASE_ATTRIBUTES = %i[id created_at variants custom_fields offer_code refunded chargebacked
                                     subscription_ended_at subscription_cancelled_at subscription_failed_at].freeze

  RAISE_ERROR_ON_PRODUCT_PERMALINK_PARAM_AFTER = 30.days

  PRODUCT_PERMALINK_SELLER_NOTIFICATION_INTERVAL = 5.days
  private_constant :PRODUCT_PERMALINK_SELLER_NOTIFICATION_INTERVAL

  def enable
    @license.enable!

    success_with_license
  end

  def disable
    @license.disable!

    success_with_license
  end

  def rotate
    @license.rotate!

    success_with_license
  end

  def verify
    return render json: { success: false, message: "This license key has been disabled." }, status: :not_found if @license.disabled?

    update_license_uses
    success_with_license
  end

  def decrement_uses_count
    @license.with_lock do
      @license.decrement!(:uses) if @license.uses > 0
    end

    success_with_license
  end

  private
    def validate_license_user
      e404_json if @license.link.user != current_resource_owner
    end

    def update_license_uses
      @license.increment!(:uses) if params[:increment_uses_count]
    end

    def fetch_valid_license
      if params[:product_id].present?
        product = Link.find_by_external_id(params[:product_id])
        @license = product.licenses.find_by(serial: params[:license_key]) if product.present?
      else
        @license = License.find_by(serial: params[:license_key])
        product = @license&.link
      end

      # Force sellers to use product_id param in license verification request
      if params[:product_id].blank? \
        && product.present? \
        && !skip_product_id_check(product)

        # Raise HTTP 500 if the product is created on or after a specific date
        if force_product_id_timestamp.present? && product.created_at > force_product_id_timestamp
          Rails.logger.error("[License Verification Error] product_id missing, responding with HTTP 500 for product: #{product.id}")
          message = "The 'product_id' parameter is required to verify the license for this product. "
          message += "Please set 'product_id' to '#{@license.link.external_id}' in the request."
          return render json: { success: false, message: }, status: :internal_server_error
        end
      end

      # Skip verifying product_permalink when product_id is present
      if @license.blank? || (params[:product_id].blank? && !product.matches_permalink?(params[:product_permalink]))
        message = "That license does not exist for the provided product."
        render json: { success: false, message: }, status: :not_found
      elsif @license.purchase&.is_access_revoked?
        message = "Access to the purchase associated with this license has expired."
        render json: { success: false, message: }, status: :not_found
      end
    end

    def success_with_license
      Rails.logger.info("License information for #{@license.serial} , license.purchase: #{@license.purchase&.id} , license.imported_customer: #{@license.imported_customer&.id}")
      json = { success: true }.merge(@license.as_json(only: [:uses]))
      if @license.purchase.present?
        purchase = @license.purchase
        json[:purchase] = purchase.payload_for_ping_notification.merge(purchase_as_json(purchase))
      elsif @license.imported_customer.present?
        json[:imported_customer] = @license.imported_customer.as_json(without_license_key: true)
      end
      render json:
    end

    def clean_params
      # `link_id` and `id` are legacy ways to pass in the product's permalink, no longer documented but used in the wild
      # The order of these parameters matters to properly support legacy requests!
      params[:product_permalink] = params[:id].presence || params[:link_id].presence || params[:product_permalink].presence

      params[:increment_uses_count] = ["false", false].exclude?(params[:increment_uses_count])
    end

    def purchase_as_json(purchase)
      json = purchase.as_json_for_license
      json.keep_if { |key, _| WHITELIST_PURCHASE_ATTRIBUTES.include? key }
      json
    end

    # Temporary debug output
    def log_params
      logger.info "Verify license API request: #{params.inspect}"
    end

    def redis_namespace
      @_redis_namespace ||= Redis::Namespace.new(:license_verifications, redis: $redis)
    end

    def skip_product_id_check(product)
      redis_namespace.get("skip_product_id_check_#{product.id}").present?
    end

    def force_product_id_timestamp
      @_force_prouct_id_timestamp ||= $redis.get(RedisKey.force_product_id_timestamp)&.to_datetime
    end
end
