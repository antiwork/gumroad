# frozen_string_literal: true

# Stateless API calls we need to make for the frontend to setup future charges for given CC, before passing this
# CC data to be saved/charged along with the preorder, subscription, or bundle payment.
class Stripe::SetupIntentsController < ApplicationController
  SESSION_SETUP_INTENT_KEY = :indian_card_mandate_setup_intents
  # The session lives in a cookie. Keeps the newest few, enough for a buyer who tries a second card and returns to the first.
  MAX_SESSION_SETUP_INTENTS = 5
  PROVIDER_UNAVAILABLE_MESSAGE = "There is a temporary problem, please try again (your card was not charged)."

  before_action :validate_card_params, only: %i[create]

  def create
    subscription = authenticated_subscription
    return if performed?

    chargeable = CardParamsHelper.build_chargeable(params)

    if chargeable.nil?
      logger.error "Error while creating setup intent: failed to load chargeable"
      render json: { success: false, error_message: "We couldn't charge your card. Try again or use a different card." }, status: :unprocessable_entity
      return
    end

    chargeable.prepare!

    pending_card = reusable_pending_card(subscription, chargeable)
    return if performed?

    if pending_card.present?
      render json: {
        success: true,
        reusable_token: pending_card.stripe_customer_id,
        setup_intent_id: pending_card.stripe_setup_intent_id,
        payment_method_id: pending_card.processor_payment_method_id
      }
      return
    end

    reusable_token = chargeable.reusable_token_for!(StripeChargeProcessor.charge_processor_id, logged_in_user)

    if skip_setup_intent_for_new_registration?(subscription)
      render json: { success: true, reusable_token:, setup_intent_skipped: true }
      return
    end

    mandate_options = mandate_options_for_stripe(chargeable, subscription:)

    setup_intent = ChargeProcessor.setup_future_charges!(merchant_account, chargeable, mandate_options:)

    remember_setup_intent(subscription, setup_intent)

    if setup_intent.succeeded?
      render json: { success: true, reusable_token:, setup_intent_id: setup_intent.id }
    elsif setup_intent.requires_action?
      render json: { success: true, reusable_token:, setup_intent_id: setup_intent.id, requires_card_setup: true, client_secret: setup_intent.client_secret }
    else
      render json: { success: false, error_message: "Sorry, something went wrong." }, status: :unprocessable_entity
    end

  rescue ChargeProcessorInvalidRequestError, ChargeProcessorUnavailableError => e
    logger.error "Error while creating setup intent: `#{e.message}`"
    render_provider_unavailable
  rescue ChargeProcessorCardError => e
    logger.error "Error while creating setup intent: `#{e.message}`"
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

    def reusable_pending_card(subscription, chargeable)
      return if subscription.blank?
      # Not every payment method has a fingerprint, and nil must never match nil.
      return if chargeable.fingerprint.blank?
      return unless subscription.credit_card&.stripe_fingerprint == chargeable.fingerprint
      return unless pending_card_reuse_authorized?(subscription)

      subscription.reusable_pending_indian_card(
        billing_info: billing_info_params,
        authenticated_offer_code_buyer: logged_in_user
      )
    rescue ChargeProcessorInvalidRequestError
      # Only a stale or invalid stored id may fall through to a new SetupIntent.
      nil
    rescue StandardError => e
      # Fail closed: a lookup we could not complete must not create a second SetupIntent and mandate for the same card.
      ErrorNotifier.notify(e, subscription: subscription&.external_id)
      render_provider_unavailable
      nil
    end

    def render_provider_unavailable
      render json: { success: false, error_message: PROVIDER_UNAVAILABLE_MESSAGE }, status: :service_unavailable
    end

    # A guest's email and permalink must not unlock stored Stripe ids: the caller owns the subscription,
    # holds its manage cookie, or created the stored setup intent in this session.
    def pending_card_reuse_authorized?(subscription)
      return true if logged_in_user.present? && logged_in_user.id == subscription.user_id

      cookie = cookies.encrypted[subscription.cookie_key]
      return true if cookie.present? && ActiveSupport::SecurityUtils.secure_compare(cookie, subscription.external_id)

      stored_setup_intent_id = subscription.credit_card.stripe_setup_intent_id
      stored_setup_intent_id.present? && minted_setup_intents.include?([subscription.external_id, stored_setup_intent_id])
    end

    def minted_setup_intents
      Array(session[SESSION_SETUP_INTENT_KEY])
    end

    # Appends rather than overwrites, so a second card tried in this session keeps the first one reusable.
    def remember_setup_intent(subscription, setup_intent)
      return if subscription.blank?

      entry = [subscription.external_id, setup_intent.id]
      session[SESSION_SETUP_INTENT_KEY] = (minted_setup_intents - [entry] + [entry]).last(MAX_SESSION_SETUP_INTENTS)
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
        if subscription&.india_card_mandate_reliability_enabled?
          terms, mandate_rate = subscription.indian_card_mandate_terms_with_rate(
            billing_info: billing_info_params,
            authenticated_offer_code_buyer: logged_in_user
          )
          return if terms.blank?

          return {
            metadata: {
              gumroad_subscription_id: subscription.external_id,
              gumroad_mandate_rate: mandate_rate
            }.compact,
            payment_method_options: {
              card: {
                mandate_options: {
                  reference: StripeChargeProcessor.indian_card_mandate_reference(subscription.external_id),
                  amount_type: "maximum",
                  amount: terms[:amount],
                  currency: terms[:currency],
                  start_date: Time.current.to_i,
                  interval: terms[:interval],
                  interval_count: terms[:interval_count],
                  supported_types: ["india"]
                }.compact
              }
            }
          }
        end

        # In case of checkout, create mandate with max product price,
        # as that is what we'd create an off-session charge for at max
        max_product_price = product_params_list.max_by { _1["price"].to_i }&.fetch("price", 0).to_i
        mandate_amount = if max_product_price.positive?
          max_product_price
        elsif subscription.present?
          subscription.current_subscription_price_cents(authenticated_offer_code_buyer: logged_in_user)
        else
          0
        end

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

    def authenticated_subscription
      subscription_id = product_params["subscription_id"]
      return restartable_checkout_subscription if subscription_id.blank?

      subscription = Subscription.find_by_external_id(subscription_id)
      unless subscription.present? && cookies.encrypted[subscription.cookie_key] == subscription.external_id
        render json: { success: false, error_message: "We could not verify this subscription." }, status: :not_found
        return
      end

      subscription
    end

    def restartable_checkout_subscription
      future_charge_product_params = product_params_list.filter_map do |product_params|
        product = Link.find_by(unique_permalink: product_params["permalink"]) if product_params["permalink"].present?
        [product, product_params] if product_requires_future_authorization?(product)
      end
      return unless future_charge_product_params.one?

      product, product_params = future_charge_product_params.first
      return unless product.is_recurring_billing?
      return if ActiveModel::Type::Boolean.new.cast(product_params["force_new_subscription"])

      subscription = if logged_in_user.present?
        Subscription.restartable_for_product_and_buyer(product:, buyer: logged_in_user)
      elsif params[:email].present?
        Subscription.restartable_for_product_and_email(product:, email: params[:email])
      end
      return if subscription.nil?

      subscription if subscription&.india_card_mandate_reliability_enabled?
    end

    def product_requires_future_authorization?(product)
      product.present? && (
        product.is_recurring_billing? ||
        product.is_in_preorder_state? ||
        product.native_type == Link::NATIVE_TYPE_COMMISSION ||
        product.installment_plan.present?
      )
    end

    def skip_setup_intent_for_new_registration?(subscription)
      return false if subscription.present?
      return false unless ActiveModel::Type::Boolean.new.cast(params[:mandate_reliability_setup])
      return false unless product_params_list.one?

      product = Link.find_by(unique_permalink: product_params["permalink"])
      return false unless product&.is_recurring_billing?

      seller = product.user
      account = seller.merchant_account(StripeChargeProcessor.charge_processor_id) ||
        MerchantAccount.gumroad(StripeChargeProcessor.charge_processor_id)
      Feature.active?(StripeChargeProcessor::INDIA_CARD_MANDATE_RELIABILITY_FEATURE, seller) &&
        !StripeIntentChargeRouting.direct_charge_account?(account)
    end

    def product_params
      product_params_list.first || {}
    end

    def billing_info_params
      params.permit(billing_info: [:country, :state, :postal_code])
            .to_h
            .fetch("billing_info", nil)
    end

    def product_params_list
      @product_params_list ||= params.permit(products: [:price, :subscription_id, :permalink, :force_new_subscription])
                                     .to_h
                                     .fetch("products", [])
    end
end
