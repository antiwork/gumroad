# frozen_string_literal: true

# Stateless API calls we need to make for the frontend to setup future charges for given CC, before passing this
# CC data to be saved/charged along with the preorder, subscription, or bundle payment.
class Stripe::SetupIntentsController < ApplicationController
  before_action :validate_card_params, only: %i[create]

  def create
    chargeable = CardParamsHelper.build_chargeable(params)

    if chargeable.nil?
      logger.error "Error while creating setup intent: failed to load chargeable for params: #{params}"
      render json: { success: false, error_message: "We couldn't charge your card. Try again or use a different card." }, status: :unprocessable_entity
      return
    end

    chargeable.prepare!
    reusable_token = chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, logged_in_user)

    mandate_options = mandate_options_for_stripe(chargeable)

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

    def mandate_options_for_stripe(chargeable)
      if chargeable.requires_mandate?
        # In case of checkout, create mandate with max product price,
        # as that is what we'd create an off-session charge for at max
        max_product_price = params.permit(products: [:price]).to_h.values.first.max_by { _1["price"].to_i }["price"].to_i rescue 0

        # In case of subscription update, create mandate with current subscription price,
        # as price in params is 0 if there's no change in price
        subscription_id = params.permit(products: [:subscription_id]).to_h.values.first[0]["subscription_id"] rescue nil
        subscription_current_amount = subscription_id.present? ? Subscription.find_by_external_id(subscription_id).current_subscription_price_cents : 0

        mandate_amount = max_product_price > 0 ? max_product_price : subscription_current_amount

        mandate_amount > 0 ?
          {
            payment_method_options: {
              card: {
                mandate_options: {
                  reference: StripeChargeProcessor::MANDATE_PREFIX + SecureRandom.hex,
                  amount_type: "maximum",
                  amount: mandate_amount,
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
end
