# frozen_string_literal: true

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
      update_original_purchase_for_offer_code_change!

      result = Subscription::UpdaterService.new(
        subscription: subscription,
        params: updater_service_params,
        logged_in_user: buyer,
        gumroad_guid: params.dig(:purchase, :browser_guid),
        remote_ip: params[:remote_ip]
      ).perform

      raise ActiveRecord::Rollback unless result[:success]
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
        quantity: params[:quantity]&.to_i.presence || subscription.original_purchase.quantity,
        use_existing_card: use_existing_card?,
        card_data_handling_mode: params[:card_data_handling_mode],
        stripe_payment_method_id: params[:stripe_payment_method_id],
        paypal_order_id: params[:paypal_order_id],
        stripe_customer_id: params[:stripe_customer_id],
        stripe_setup_intent_id: params[:stripe_setup_intent_id],
      }.compact
    end

    # When the offer code terms have changed since the original purchase,
    # create a new original_purchase with the current offer code values
    # (similar to how plan/recurrence changes are handled via update_current_plan!).
    # This preserves historical data on the old purchase instead of overwriting it.
    def update_original_purchase_for_offer_code_change!
      original_purchase = subscription.original_purchase
      discount = original_purchase.purchase_offer_code_discount
      return if discount.blank?

      offer_code = discount.offer_code
      return if offer_code.blank?

      return if discount.offer_code_amount == offer_code.amount &&
                discount.offer_code_is_percent == offer_code.is_percent? &&
                discount.duration_in_billing_cycles == offer_code.duration_in_billing_cycles

      subscription.update_current_plan!(
        new_variants: original_purchase.variant_attributes.to_a,
        new_price: subscription.price,
        new_quantity: original_purchase.quantity,
        offer_code_attrs: {
          offer_code_amount: offer_code.amount,
          offer_code_is_percent: offer_code.is_percent?,
          duration_in_months: offer_code.duration_in_billing_cycles
        }
      )
      subscription.reload
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
