# frozen_string_literal: true

class Subscription::RestartAtCheckoutService
  include CurrencyHelper

  class ChargeFailed < StandardError
    attr_reader :purchase

    def initialize(message, purchase: nil)
      super(message)
      @purchase = purchase
    end
  end

  attr_reader :subscription, :product, :params, :buyer
  attr_accessor :new_purchase

  def initialize(subscription:, product:, params:, buyer: nil)
    @subscription = subscription
    @product = product
    @params = params
    @buyer = buyer
    @new_purchase = nil
  end

  def perform
    error = validate_restart
    return error_result(error) if error.present?

    ActiveRecord::Base.transaction do
      handle_tier_change if tier_changed?
      update_payment_method if should_update_payment_method?
      subscription.resubscribe!

      if should_charge?
        charge_result = charge_subscription
        self.new_purchase = charge_result[:purchase]
      end

      subscription.send_restart_notifications!
      success_result
    end
  rescue ChargeFailed => e
    subscription.reload
    subscription.unsubscribe_and_fail!
    error_result(e.message)
  rescue ActiveRecord::RecordInvalid, Subscription::UpdateFailed => e
    error_result(e.message)
  rescue StandardError => e
    Rails.logger.error("Subscription::RestartAtCheckoutService error: #{e.message}")
    Bugsnag.notify(e)
    error_result("Sorry, something went wrong. Please try again.")
  end

  private
    def validate_restart
      return "This subscription cannot be restarted." if subscription.cancelled_by_seller?
      return "This subscription cannot be restarted." if product.deleted?
      return "This installment plan has already been completed and cannot be restarted." if subscription.is_installment_plan? && subscription.charges_completed?
      nil
    end

    def tier_changed?
      return false unless product.is_tiered_membership?
      return false unless params[:variants].present?

      selected_tier_ids = params[:variants].map { |id| product.tiers.find_by_external_id(id)&.id }.compact
      current_tier_ids = subscription.original_purchase.variant_attributes.map(&:id)

      selected_tier_ids.sort != current_tier_ids.sort
    end

    def handle_tier_change
      new_variants = params[:variants].map { |id| product.tiers.find_by_external_id(id) }.compact
      perceived_price_cents = params.dig(:purchase, :perceived_price_cents)&.to_i

      subscription.update_current_plan!(
        new_variants: new_variants,
        new_price: determine_new_price,
        perceived_price_cents: perceived_price_cents
      )
      subscription.reload
    end

    def determine_new_price
      if params[:price_id].present?
        product.prices.alive.find_by_external_id(params[:price_id])
      else
        product.default_price
      end
    end

    def should_update_payment_method?
      card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
      card_data_handling_mode.present? && card_data_handling_mode != :reuse
    end

    def update_payment_method
      card_data_handling_mode = CardParamsHelper.get_card_data_handling_mode(params)
      card_data_handling_error = CardParamsHelper.check_for_errors(params)
      chargeable = CardParamsHelper.build_chargeable(params.merge(product_permalink: product.unique_permalink))

      if card_data_handling_error.present?
        raise Subscription::UpdateFailed, card_data_handling_error.is_card_error? ?
          PurchaseErrorCode.customer_error_message(card_data_handling_error.error_message) :
          "There is a temporary problem, please try again (your card was not charged)."
      end

      unless chargeable.present?
        raise Subscription::UpdateFailed, "We couldn't process your card. Try again or use a different card."
      end

      credit_card = CreditCard.create(chargeable, card_data_handling_mode, buyer)

      unless credit_card.errors.empty?
        raise Subscription::UpdateFailed, credit_card.errors.messages[:base].first
      end

      subscription.credit_card = credit_card
      subscription.save!
    end

    def should_charge?
      !within_billing_period? && !subscription.in_free_trial?
    end

    def within_billing_period?
      subscription.end_time_of_last_paid_period&.future? ||
        subscription.free_trial_ends_at&.future?
    end

    def charge_subscription
      perceived_price_cents = params.dig(:purchase, :perceived_price_cents)&.to_i ||
                              subscription.current_subscription_price_cents

      purchase = subscription.charge!(
        override_params: {
          perceived_price_cents: perceived_price_cents,
          browser_guid: params.dig(:purchase, :browser_guid)
        },
        off_session: false
      )

      if purchase.successful? || purchase.test_successful?
        { success: true, purchase: purchase }
      elsif purchase.in_progress? && purchase.charge_intent&.requires_action?
        {
          success: true,
          requires_card_action: true,
          purchase: purchase,
          client_secret: purchase.charge_intent.client_secret,
          stripe_connect_account_id: purchase.merchant_account.is_a_stripe_connect_account? ?
            purchase.merchant_account.charge_processor_merchant_id : nil
        }
      else
        # Raise exception to trigger transaction rollback before marking subscription as failed
        # This ensures tier changes, payment method updates, and resubscribe! are all rolled back
        error_message = purchase.errors.full_messages.first || purchase.error_code || "Payment failed. Please try again."
        raise ChargeFailed.new(error_message, purchase: purchase)
      end
    end

    def success_result
      {
        success: true,
        restarted_subscription: true,
        subscription: subscription,
        purchase: new_purchase,
        message: "Your membership has been restarted!"
      }
    end

    def error_result(message)
      { success: false, error_message: message }
    end
end
