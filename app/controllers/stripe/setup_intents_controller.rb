# frozen_string_literal: true

# Stateless API calls we need to make for the frontend to setup future charges for given CC, before passing this
# CC data to be saved/charged along with the preorder, subscription, or bundle payment.
class Stripe::SetupIntentsController < ApplicationController
  include CurrencyHelper

  before_action :validate_card_params, only: %i[create]

  def create
    subscription = authenticated_subscription
    return if performed?

    chargeable = CardParamsHelper.build_chargeable(params)

    if chargeable.nil?
      logger.error "Error while creating setup intent: failed to load chargeable for params: #{params}"
      render json: { success: false, error_message: "We couldn't charge your card. Try again or use a different card." }, status: :unprocessable_entity
      return
    end

    chargeable.prepare!
    reusable_token = chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, logged_in_user)

    mandate_options = mandate_options_for_stripe(chargeable, subscription:)

    setup_intent = ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)

    if setup_intent.succeeded?
      render json: { success: true, reusable_token:, setup_intent_id: setup_intent.id }
    elsif setup_intent.requires_action?
      render json: { success: true, reusable_token:, setup_intent_id: setup_intent.id, requires_card_setup: true, client_secret: setup_intent.client_secret }
    else
      render json: { success: false, error_message: "Sorry, something went wrong." }, status: :unprocessable_entity
    end

  rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
    logger.error "Error while creating setup intent: `#{e.message}` for params: #{params}"
    render json: { success: false, error_message: "There is a temporary problem, please try again (your card was not charged)." }, status: :service_unavailable
  rescue ChargeProcessorCardError => e
    logger.error "Error while creating setup intent: `#{e.message}` for params: #{params}"
    render json: { success: false, error_message: PurchaseErrorCode.customer_error_message(e.message), error_code: e.error_code }, status: :unprocessable_entity
  end

  private
    def validate_card_params
      card_data_handling_error = CardParamsHelper.check_for_errors(params)

      if card_data_handling_error.present?
        logger.error("Error while creating setup intent: #{card_data_handling_error.error_message} #{card_data_handling_error.card_error_code}")
        error_message = card_data_handling_error.is_card_error? ? PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message) : "There is a temporary problem, please try again (your card was not charged)."

        render json: { success: false, error_message: }, status: :unprocessable_entity
      end
    end

    def merchant_account
      processor_id = StripeChargeProcessor.charge_processor_id

      if params[:permalink].present?
        link = Link.find_by unique_permalink: params[:permalink]
        link&.user&.merchant_account(processor_id) || MerchantAccount.gumroad(processor_id)
      else
        MerchantAccount.gumroad(processor_id)
      end
    end

    def mandate_options_for_stripe(chargeable, subscription: nil)
      if chargeable.requires_mandate?
        if subscription.present?
          mandate_amount = product_params["renewalPriceCents"].to_i
          unless mandate_amount.positive?
            current_price = subscription.current_subscription_price_cents(authenticated_offer_code_buyer: logged_in_user)
            mandate_amount = get_usd_cents(subscription.link.price_currency_type, current_price)
          end
          return if mandate_amount <= 0

          interval, interval_count = mandate_interval(product_params["recurrence"].presence || subscription.recurrence)
          return {
            metadata: { gumroad_subscription_id: subscription.external_id },
            payment_method_options: {
              card: {
                mandate_options: {
                  reference: StripeChargeProcessor::MANDATE_PREFIX + subscription.external_id,
                  amount_type: "maximum",
                  amount: mandate_amount,
                  currency: Currency::USD,
                  start_date: Time.current.to_i,
                  interval:,
                  interval_count:,
                  supported_types: ["india"]
                }
              }
            }
          }
        end

        # In case of checkout, create mandate with max product price,
        # as that is what we'd create an off-session charge for at max
        max_product_price = product_params_list.max_by { _1["price"].to_i }&.fetch("price", 0).to_i

        max_product_price > 0 ?
          {
            payment_method_options: {
              card: {
                mandate_options: {
                  reference: StripeChargeProcessor::MANDATE_PREFIX + SecureRandom.hex,
                  amount_type: "maximum",
                  amount: max_product_price,
                  currency: "usd",
                  start_date: Time.current.to_i,
                  interval: "sporadic",
                  supported_types: ["india"]
                }
              }
            }
          } : nil
      end
    end

    def authenticated_subscription
      subscription_id = product_params["subscription_id"]
      return if subscription_id.blank?

      subscription = Subscription.find_by_external_id(subscription_id)
      unless subscription.present? && cookies.encrypted[subscription.cookie_key] == subscription.external_id
        render json: { success: false, error_message: "We could not verify this subscription." }, status: :not_found
        return
      end

      subscription
    end

    def product_params
      product_params_list.first || {}
    end

    def product_params_list
      @product_params_list ||= params.permit(products: [:price, :renewalPriceCents, :recurrence, :subscription_id])
                                     .to_h
                                     .fetch("products", [])
    end

    def mandate_interval(recurrence)
      case recurrence
      when "every_two_years"
        ["year", 2]
      when "yearly"
        ["year", 1]
      when "quarterly"
        ["month", 3]
      when "biannually"
        ["month", 6]
      when "monthly"
        ["month", 1]
      else
        ["sporadic", nil]
      end
    end
end
