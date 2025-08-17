# frozen_string_literal: true

module Purchase::PaymentProcessing
  extend ActiveSupport::Concern

  def charge!(off_session: false, merchant_account: nil)
    raise Purchase::PurchaseInvalid, "Purchase already charged" if successful?

    self.merchant_account = merchant_account || determine_merchant_account

    if free_purchase?
      process_free_purchase!
    else
      process_paid_purchase!(off_session: off_session)
    end
  end

  def sync_status_with_charge_processor(mark_as_failed: false)
    return false if charge_processor_id.blank?

    case charge_processor_id
    when ChargeProcessor::STRIPE
      sync_with_stripe(mark_as_failed: mark_as_failed)
    when ChargeProcessor::PAYPAL
      sync_with_paypal(mark_as_failed: mark_as_failed)
    else
      false
    end
  end

  def can_force_update?
    in_progress? && created_at < 4.hours.ago
  end

  private

  def process_free_purchase!
    self.state = "not_charged"
    self.charge_date = Time.current
    save!
    execute_purchase_completion_handler
  end

  def process_paid_purchase!(off_session:)
    create_charge_intent(off_session: off_session)
    process_payment_method
    handle_payment_result
  end

  def determine_merchant_account
    seller.merchant_account || seller.build_default_merchant_account
  end

  def sync_with_stripe(mark_as_failed:)
    return false unless stripe_payment_intent_id.present?

    payment_intent = Stripe::PaymentIntent.retrieve(stripe_payment_intent_id)
    update_from_stripe_payment_intent(payment_intent, mark_as_failed: mark_as_failed)
  rescue Stripe::StripeError => e
    Rails.logger.error("Failed to sync with Stripe: #{e.message}")
    false
  end

  def sync_with_paypal(mark_as_failed:)
    return false unless paypal_order_id.present?

    order = PayPal::Order.retrieve(paypal_order_id)
    update_from_paypal_order(order, mark_as_failed: mark_as_failed)
  rescue PayPal::PayPalError => e
    Rails.logger.error("Failed to sync with PayPal: #{e.message}")
    false
  end

  def update_from_stripe_payment_intent(payment_intent, mark_as_failed:)
    case payment_intent.status
    when "succeeded"
      mark_as_successful!
    when "canceled", "payment_failed"
      mark_as_failed! if mark_as_failed
    when "requires_action"
      self.requires_sca = true
      save!
    end
    true
  end

  def update_from_paypal_order(order, mark_as_failed:)
    case order.status
    when "COMPLETED"
      mark_as_successful!
    when "CANCELLED", "FAILED"
      mark_as_failed! if mark_as_failed
    end
    true
  end
end
