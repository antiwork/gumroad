# frozen_string_literal: true

class OrdersController < ApplicationController
  include ValidateRecaptcha, Events, Order::ResponseHelpers

  before_action :validate_order_request, only: :create
  before_action :fetch_affiliates, only: :create

  def create
    order_params = permitted_order_params.merge!(
      {
        browser_guid: cookies[:_gumroad_guid],
        session_id: session.id,
        ip_address: request.remote_ip,
        is_mobile: is_mobile?
      }
    ).to_h

    order, purchase_responses, offer_codes = Order::CreateService.new(
      buyer: logged_in_user,
      params: order_params
    ).perform

    charge_responses = Order::ChargeService.new(order:, params: order_params).perform

    if order.persisted? && order.purchases.successful.any? && UtmLinkVisit.where(browser_guid: order_params[:browser_guid]).any?
      UtmLinkSaleAttributionJob.perform_async(order.id, order_params[:browser_guid])
    end

    purchase_responses.merge!(charge_responses)

    order.purchases.each { create_purchase_event_and_recommendation_info(_1) }
    order.send_charge_receipts unless purchase_responses.any? { |_k, v| v[:requires_card_action] || v[:requires_card_setup] }

    render json: { success: true, line_items: purchase_responses, offer_codes:, can_buyer_sign_up: }
  end

  def confirm
    ActiveRecord::Base.connection.stick_to_primary!

    order = Order.find_by_external_id(params[:id])
    e404 unless order

    confirm_responses, offer_codes = Order::ConfirmService.new(order:, params:).perform

    confirm_responses.each do |purchase_id, response|
      next unless response[:success]

      purchase = Purchase.find(purchase_id)
      create_purchase_event_and_recommendation_info(purchase)
    end
    order.send_charge_receipts

    render json: { success: true, line_items: confirm_responses, offer_codes:, can_buyer_sign_up: }
  end

  private
    def validate_order_request
      # Don't allow the order to go through if the buyer is a bot. Pretend that the order succeeded instead.
      return render json: { success: true } if is_bot?

      # Don't allow the order to go through if cookies are disabled and it's a paid order
      contains_paid_purchase = if params[:line_items].present?
        params[:line_items].any? { |product_params| product_params[:perceived_price_cents] != "0" }
      else
        params[:perceived_price_cents] != "0"
      end
      browser_guid = cookies[:_gumroad_guid]
      return render_error("Cookies are not enabled on your browser. Please enable cookies and refresh this page before continuing.") if contains_paid_purchase && browser_guid.blank?

      # Verify reCAPTCHA response
      if !skip_recaptcha? && !valid_recaptcha_response_and_hostname?(site_key: GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY"))
        render_error("Sorry, we could not verify the CAPTCHA. Please try again.")
      end
    end

    def skip_recaptcha?
      site_key = GlobalConfig.get("RECAPTCHA_MONEY_SITE_KEY")
      return true if (Rails.env.development? || Rails.env.test?) && site_key.blank?
      return true if action_name == "create" && all_free_products_without_captcha?
      return true if valid_wallet_payment?

      false
    end

    def all_free_products_without_captcha?
      line_items = params.fetch(:line_items, {})
      line_items.all? do |product|
        product_link = Link.find_by(unique_permalink: product["permalink"])
        !product_link.require_captcha? && product["perceived_price_cents"].to_s == "0"
      end
    end

    def valid_wallet_payment?
      return false if [params[:wallet_type], params[:stripe_payment_method_id]].any?(&:blank?)
      payment_method = Stripe::PaymentMethod.retrieve(params[:stripe_payment_method_id])
      payment_method&.card&.wallet&.type == params[:wallet_type]
    rescue Stripe::StripeError
      render_error("Sorry, something went wrong.")
    end

    def permitted_order_params
      params.permit(
        # Common params across all purchases of the order
        :friend, :locale, :plugins, :save_card, :card_data_handling_mode, :card_data_handling_error,
        :card_country, :card_country_source, :wallet_type, :cc_zipcode, :vat_id, :email, :tax_country_election,
        :save_shipping_address, :card_expiry_month, :card_expiry_year, :stripe_status, :visual,
        :billing_agreement_id, :paypal_order_id, :stripe_payment_method_id, :stripe_customer_id, :stripe_error,
        :braintree_transient_customer_store_key, :braintree_device_data, :use_existing_card, :paymentToken,
        :url_parameters, :is_gift, :giftee_email, :giftee_id, :gift_note, :referrer,
        purchase: [:full_name, :street_address, :city, :state, :zip_code, :country],
        # Individual purchase params
        line_items: [:uid, :permalink, :perceived_price_cents, :price_range, :discount_code, :is_preorder, :quantity, :call_start_time,
                     :was_product_recommended, :recommended_by, :referrer, :is_rental, :is_multi_buy,
                     :was_discover_fee_charged, :price_cents, :tax_cents, :gumroad_tax_cents, :shipping_cents, :price_id, :affiliate_id, :url_parameters, :is_purchasing_power_parity_discounted,
                     :recommender_model_name, :tip_cents, :pay_in_installments,
                     custom_fields: [:id, :value], variants: [], perceived_free_trial_duration: [:unit, :amount], accepted_offer: [:id, :original_variant_id, :original_product_id],
                     bundle_products: [:product_id, :variant_id, :quantity, custom_fields: [:id, :value]]])
    end

    def fetch_affiliates
      line_items = params.fetch(:line_items, [])
      line_items.each do |line_item_params|
        product = Link.find_by(unique_permalink: line_item_params[:permalink])

        # In the case a purchase is both recommended and has an affiliate, recommendation takes priority
        # so don't include the affiliate unless it is a global affiliate
        affiliate = fetch_affiliate(product, line_item_params)
        line_item_params.delete(:affiliate_id)
        line_item_params[:affiliate_id] = affiliate.id if affiliate&.eligible_for_purchase_credit?(product:, was_recommended: line_item_params[:was_product_recommended] && line_item_params[:recommended_by] != RecommendationType::GUMROAD_MORE_LIKE_THIS_RECOMMENDATION, purchaser_email: params[:email])
      end
    end

    def create_purchase_event_and_recommendation_info(purchase)
      create_purchase_event(purchase)
      purchase.handle_recommended_purchase if purchase.was_product_recommended
    end

    def render_error(error_message, purchase: nil)
      render json: error_response(error_message, purchase:)
    end

    def can_buyer_sign_up
      !logged_in_user && User.alive.where(email: params[:email]).none?
    end
end
