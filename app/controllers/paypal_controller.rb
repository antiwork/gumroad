# frozen_string_literal: true

class PaypalController < ApplicationController
  before_action :authenticate_user!, only: [:connect, :disconnect]
  before_action :validate_paypal_connect_allowed, only: %i[connect]
  before_action :validate_paypal_disconnect_allowed, only: %i[disconnect]
  after_action :verify_authorized, only: [:connect, :disconnect]

  def billing_agreement_token
    begin
      Rails.logger.info("Generate billing agreement token params - #{params}")
      billing_agreement_token_id = PaypalChargeProcessor.generate_billing_agreement_token(shipping: params[:shipping] == "true")
    rescue ChargeProcessorError => e
      Rails.logger.error("PAYPAL BUYER UX AFFECTING ERROR-in #{__method__}-#{e.message}")
    end

    render json: { billing_agreement_token_id: }
  end

  def billing_agreement
    begin
      Rails.logger.info("Create billing agreement params - #{params}")
      response = PaypalChargeProcessor.create_billing_agreement(billing_agreement_token_id: params[:billing_agreement_token_id])
    rescue ChargeProcessorError => e
      Rails.logger.error("PAYPAL BUYER UX AFFECTING ERROR-in #{__method__}-#{e.message}")
    end

    render json: response
  end

  def order
    begin
      product = Link.find_by_external_id(params[:product][:external_id])
      affiliate = fetch_affiliate(product)
      if affiliate&.eligible_for_purchase_credit?(product:, was_recommended: !!params[:product][:was_recommended])
        params[:product][:affiliate_id] = affiliate.id
      end
      order_id = PaypalChargeProcessor.create_order_from_product_info(params[:product])
    rescue ChargeProcessorError => e
      Rails.logger.error("PAYPAL BUYER UX AFFECTING ERROR-in #{__method__}-#{e.message}")
    end

    render json: { order_id: }
  end

  def fetch_order
    begin
      api_response = PaypalChargeProcessor.fetch_order(order_id: params[:order_id])
    rescue ChargeProcessorError => e
      Rails.logger.error("PAYPAL BUYER UX AFFECTING ERROR-in #{__method__}-#{e.message}")
    end

    render json: api_response || {}
  end

  def update_order
    begin
      success = PaypalChargeProcessor.update_order_from_product_info(params[:order_id], params[:product])
    rescue ChargeProcessorError => e
      Rails.logger.error("PAYPAL BUYER UX AFFECTING ERROR-in #{__method__}-#{e.message}")
    end

    render json: { success: !!success }
  end

  def connect
    authorize [:settings, :payments, current_seller], :paypal_connect?

    paypal_merchant_account_manager = PaypalMerchantAccountManager.new
    response = paypal_merchant_account_manager.create_partner_referral(current_seller, paypal_connect_settings_payments_url)

    if response[:success]
      redirect_to response[:redirect_url], allow_other_host: true
    else
      redirect_to settings_payments_path, notice: response[:error_message]
    end
  end

  def disconnect
    authorize [:settings, :payments, current_seller], :paypal_connect?

    render json: { success: PaypalMerchantAccountManager.new.disconnect(user: current_seller) }
  end

  private
    def validate_paypal_connect_allowed
      return if current_seller.paypal_connect_enabled? && current_seller.paypal_connect_allowed?

      alert = if !current_seller.paypal_connect_enabled?
        "Your PayPal account could not be connected because this PayPal integration is not supported in your country."
      elsif !current_seller.paypal_connect_allowed?
        "Your PayPal account could not be connected because you do not meet the eligibility requirements."
      end

      redirect_to settings_payments_path, alert:
    end

    def validate_paypal_disconnect_allowed
      return if current_seller.paypal_disconnect_allowed?

      redirect_to settings_payments_path, notice: "You cannot disconnect your PayPal account because it is being used for active subscription or preorder payments."
    end
end
