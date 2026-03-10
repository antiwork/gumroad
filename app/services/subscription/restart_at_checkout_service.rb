# frozen_string_literal: true

# Adapter service that transforms checkout params and delegates to UpdaterService
# for restarting cancelled/failed subscriptions during checkout.
#
# This maintains separation between checkout context and manage subscription context
# while reusing the battle-tested UpdaterService logic.
class Subscription::RestartAtCheckoutService
  attr_reader :subscription, :product, :params, :buyer

  def initialize(subscription:, product:, params:, buyer: nil)
    @subscription = subscription
    @product = product
    @params = params
    @buyer = buyer
  end

  def perform
    result = nil

    ActiveRecord::Base.transaction do
      sync_offer_code_discount_to_current!

      result = Subscription::UpdaterService.new(
        subscription: subscription,
        params: updater_service_params,
        logged_in_user: buyer,
        gumroad_guid: params.dig(:purchase, :browser_guid),
        remote_ip: params[:remote_ip]
      ).perform

      raise ActiveRecord::Rollback if !result[:success] && !result[:requires_card_action]
    end

    adapt_result(result)
  end

  private
    def updater_service_params
      perceived_price_cents = params.dig(:purchase, :perceived_price_cents)&.to_i ||
                              subscription.current_subscription_price_cents

      {
        variants: params[:variants] || default_variant_ids,
        price_id: params[:price_id] || subscription.price&.external_id,
        perceived_price_cents: perceived_price_cents,
        perceived_upgrade_price_cents: perceived_price_cents,
        quantity: subscription.original_purchase.quantity,
        use_existing_card: use_existing_card?,
        card_data_handling_mode: params[:card_data_handling_mode],
        stripe_payment_method_id: params[:stripe_payment_method_id],
        paypal_order_id: params[:paypal_order_id],
        stripe_customer_id: params[:stripe_customer_id],
        stripe_setup_intent_id: params[:stripe_setup_intent_id],
      }.compact
    end

    def sync_offer_code_discount_to_current!
      original_purchase = subscription.original_purchase
      discount = original_purchase.purchase_offer_code_discount
      return if discount.blank?

      offer_code = discount.offer_code
      return if offer_code.blank?

      current_amount = offer_code.amount
      current_is_percent = offer_code.is_percent?

      return if discount.offer_code_amount == current_amount && discount.offer_code_is_percent == current_is_percent

      discount.update!(
        offer_code_amount: current_amount,
        offer_code_is_percent: current_is_percent
      )

      pre_discount_price = original_purchase.minimum_paid_price_cents_per_unit_before_discount
      new_discount_off = offer_code.amount_off(pre_discount_price)
      new_displayed_price = [(pre_discount_price - new_discount_off) * original_purchase.quantity, 0].max

      original_purchase.update!(displayed_price_cents: new_displayed_price)
    end

    def default_variant_ids
      subscription.original_purchase.variant_attributes.map(&:external_id)
    end

    def use_existing_card?
      card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
      card_data_handling_mode.blank? || card_data_handling_mode == :reuse
    end

    def adapt_result(result)
      if result[:success]
        {
          success: true,
          restarted_subscription: true,
          subscription: subscription,
          purchase: result[:purchase].presence,
          requires_card_action: result[:requires_card_action],
          client_secret: result[:client_secret],
          message: result[:success_message] || "Your membership has been restarted!"
        }.compact
      else
        { success: false, error_message: result[:error_message] }
      end
    end
end
