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
    old_discount_attrs = snapshot_discount_attrs

    ActiveRecord::Base.transaction do
      sync_offer_code_discount_to_current!

      result = Subscription::UpdaterService.new(
        subscription: subscription,
        params: updater_service_params,
        logged_in_user: buyer,
        gumroad_guid: params.dig(:purchase, :browser_guid),
        remote_ip: params[:remote_ip]
      ).perform

      raise ActiveRecord::Rollback unless result[:success]
    end

    # When 3DS is required, revert the discount sync so it doesn't persist
    # before the buyer confirms. Purchase::ConfirmService will re-apply
    # the sync when 3DS succeeds.
    if result[:requires_card_action] && old_discount_attrs.present?
      revert_offer_code_discount_sync!(old_discount_attrs)
    end

    adapt_result(result)
  end

  # Re-applies the offer code discount sync after 3DS confirmation succeeds.
  # Called from Purchase::ConfirmService when a resubscription is confirmed.
  def self.sync_offer_code_discount!(subscription)
    original_purchase = subscription.original_purchase
    discount = original_purchase.purchase_offer_code_discount
    return if discount.blank?

    offer_code = discount.offer_code
    return if offer_code.blank?

    current_amount = offer_code.amount
    current_is_percent = offer_code.is_percent?
    current_duration = offer_code.duration_in_billing_cycles

    return if discount.offer_code_amount == current_amount &&
              discount.offer_code_is_percent == current_is_percent &&
              discount.duration_in_billing_cycles == current_duration

    discount.update!(
      offer_code_amount: current_amount,
      offer_code_is_percent: current_is_percent,
      duration_in_billing_cycles: current_duration
    )

    pre_discount_price = original_purchase.minimum_paid_price_cents_per_unit_before_discount
    new_discount_off = offer_code.amount_off(pre_discount_price)
    new_displayed_price = [(pre_discount_price - new_discount_off) * original_purchase.quantity, 0].max

    original_purchase.update!(displayed_price_cents: new_displayed_price)
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
      self.class.sync_offer_code_discount!(subscription)
    end

    def snapshot_discount_attrs
      original_purchase = subscription.original_purchase
      discount = original_purchase.purchase_offer_code_discount
      return nil if discount.blank?

      {
        offer_code_amount: discount.offer_code_amount,
        offer_code_is_percent: discount.offer_code_is_percent,
        duration_in_billing_cycles: discount.duration_in_billing_cycles,
        displayed_price_cents: original_purchase.displayed_price_cents
      }
    end

    def revert_offer_code_discount_sync!(old_attrs)
      original_purchase = subscription.original_purchase
      discount = original_purchase.purchase_offer_code_discount
      return if discount.blank?

      discount.update!(
        offer_code_amount: old_attrs[:offer_code_amount],
        offer_code_is_percent: old_attrs[:offer_code_is_percent],
        duration_in_billing_cycles: old_attrs[:duration_in_billing_cycles]
      )
      original_purchase.update!(displayed_price_cents: old_attrs[:displayed_price_cents])
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
