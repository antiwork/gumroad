# frozen_string_literal: true

# Adapter service that transforms checkout params and delegates to UpdaterService
# for restarting cancelled/failed subscriptions during checkout.
#
# This reuses the battle-tested UpdaterService logic for charging, tier changes,
# payment method updates, proration, SCA, webhooks, etc.
class Subscription::RestartAtCheckoutService
  CARD_PARAM_KEYS = %i[
    card_data_handling_mode stripe_payment_method_id stripe_customer_id
    stripe_setup_intent_id stripe_error paypal_order_id paymentToken
    billing_agreement_id braintree_device_data braintree_transient_customer_store_key
    visual card_country card_country_source
  ].freeze

  attr_reader :subscription, :product, :params, :buyer

  def initialize(subscription:, product:, params:, buyer: nil)
    @subscription = subscription
    @product = product
    @params = params
    @buyer = buyer
  end

  def perform
    result = Subscription::UpdaterService.new(
      subscription: subscription,
      params: build_updater_params,
      logged_in_user: buyer,
      gumroad_guid: params.dig(:purchase, :browser_guid),
      remote_ip: params[:remote_ip]
    ).perform

    adapt_result(result)
  end

  private
    def build_updater_params
      updater_params = {
        variants: params[:variants] || default_variant_ids,
        price_id: params[:price_id] || subscription.price&.external_id,
        quantity: subscription.original_purchase.quantity,
        perceived_price_cents: perceived_price,
        perceived_upgrade_price_cents: perceived_price,
      }

      card_mode = CardParamsHelper.get_card_data_handling_mode(merged_card_params)
      if card_mode.present? && card_mode != :reuse
        updater_params.merge!(merged_card_params.slice(*CARD_PARAM_KEYS))
      else
        updater_params[:use_existing_card] = true
      end

      updater_params
    end

    def perceived_price
      params.dig(:purchase, :perceived_price_cents)&.to_i ||
        subscription.current_subscription_price_cents
    end

    def default_variant_ids
      subscription.original_purchase.variant_attributes.map(&:external_id)
    end

    def merged_card_params
      @merged_card_params ||= params.slice(*CARD_PARAM_KEYS)
        .merge((params[:purchase] || {}).slice(*CARD_PARAM_KEYS))
    end

    def adapt_result(result)
      if result[:success]
        adapted = {
          success: true,
          restarted_subscription: true,
          subscription: subscription,
          message: result[:success_message] || "Your membership has been restarted!"
        }

        if result[:requires_card_action]
          adapted[:requires_card_action] = true
          adapted[:client_secret] = result[:client_secret]
        end

        adapted
      else
        { success: false, error_message: result[:error_message] }
      end
    end
end
