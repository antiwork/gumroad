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

    if result[:requires_card_action] && old_discount_attrs.present?
      revert_offer_code_discount_sync!(old_discount_attrs)
    end

    adapt_result(result)
  end

  # Re-applies discount values from a confirmed purchase (after 3DS) to the
  # subscription's original_purchase. Unlike sync_offer_code_discount!, this
  # reads from the purchase that was created at checkout time, not from the
  # live offer code, so it is safe against seller edits between checkout and
  # 3DS confirmation.
  def self.sync_offer_code_discount_from_confirmed_purchase!(subscription, confirmed_purchase)
    source_discount = confirmed_purchase.purchase_offer_code_discount
    return if source_discount.blank?

    target_purchase = subscription.original_purchase
    target_discount = target_purchase.purchase_offer_code_discount
    return if target_discount.blank?

    # If the confirmed purchase IS the current original purchase (plan-changed
    # case), the discount is already correct.
    return if target_discount.id == source_discount.id

    return if target_discount.offer_code_amount == source_discount.offer_code_amount &&
              target_discount.offer_code_is_percent == source_discount.offer_code_is_percent &&
              target_discount.duration_in_billing_cycles == source_discount.duration_in_billing_cycles &&
              target_discount.pre_discount_minimum_price_cents == source_discount.pre_discount_minimum_price_cents

    ActiveRecord::Base.transaction do
      target_discount.update!(
        offer_code_amount: source_discount.offer_code_amount,
        offer_code_is_percent: source_discount.offer_code_is_percent,
        duration_in_billing_cycles: source_discount.duration_in_billing_cycles,
        pre_discount_minimum_price_cents: source_discount.pre_discount_minimum_price_cents
      )

      pre_discount_price = source_discount.pre_discount_minimum_price_cents
      if source_discount.offer_code_is_percent
        discount_off = (pre_discount_price * source_discount.offer_code_amount / 100.0).round
      else
        discount_off = source_discount.offer_code_amount
      end
      target_purchase.update!(displayed_price_cents: [(pre_discount_price - discount_off) * target_purchase.quantity, 0].max)
    end
  end

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

    ActiveRecord::Base.transaction do
      discount.update!(
        offer_code_amount: current_amount,
        offer_code_is_percent: current_is_percent,
        duration_in_billing_cycles: current_duration
      )

      new_displayed_price = compute_displayed_price(original_purchase, current_amount, current_is_percent)
      original_purchase.update!(displayed_price_cents: new_displayed_price)
    end
  end

  def self.compute_displayed_price(purchase, discount_amount, is_percent)
    pre_discount_price = purchase.minimum_paid_price_cents_per_unit_before_discount
    if is_percent
      discount_off = (pre_discount_price * discount_amount / 100.0).round
    else
      discount_off = discount_amount
    end
    [(pre_discount_price - discount_off) * purchase.quantity, 0].max
  end
  private_class_method :compute_displayed_price

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

    def sync_offer_code_discount_to_current!
      self.class.sync_offer_code_discount!(subscription)
    end

    def snapshot_discount_attrs
      original_purchase = subscription.original_purchase
      discount = original_purchase.purchase_offer_code_discount
      return nil if discount.blank?

      {
        purchase_id: original_purchase.id,
        offer_code_amount: discount.offer_code_amount,
        offer_code_is_percent: discount.offer_code_is_percent,
        duration_in_billing_cycles: discount.duration_in_billing_cycles,
        displayed_price_cents: original_purchase.displayed_price_cents
      }
    end

    def revert_offer_code_discount_sync!(old_attrs)
      purchase = Purchase.find_by(id: old_attrs[:purchase_id])
      return if purchase.blank?

      discount = purchase.purchase_offer_code_discount
      return if discount.blank?

      ActiveRecord::Base.transaction do
        discount.update!(
          offer_code_amount: old_attrs[:offer_code_amount],
          offer_code_is_percent: old_attrs[:offer_code_is_percent],
          duration_in_billing_cycles: old_attrs[:duration_in_billing_cycles]
        )
        purchase.update!(displayed_price_cents: old_attrs[:displayed_price_cents])
      end
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
