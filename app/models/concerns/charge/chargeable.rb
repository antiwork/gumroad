# frozen_string_literal: true

module Charge::Chargeable
  class << self
    def find_by_stripe_event(event)
      chargeable = nil

      if event.charge_reference.to_s.starts_with?(Charge::COMBINED_CHARGE_PREFIX)
        chargeable ||= Charge.where(id: event.charge_reference.sub(Charge::COMBINED_CHARGE_PREFIX, "")).last
        chargeable ||= Charge.where(processor_transaction_id: event.charge_id).last if event.charge_id
        chargeable ||= Charge.where(stripe_payment_intent_id: event.processor_payment_intent_id).last if event.processor_payment_intent_id.present?
      else
        chargeable = Purchase.find_by_external_id(event.charge_reference) if event.charge_reference
        chargeable ||= Purchase.where(stripe_transaction_id: event.charge_id).last if event.charge_id
        chargeable ||= ProcessorPaymentIntent.where(intent_id: event.processor_payment_intent_id).last&.purchase if event.processor_payment_intent_id.present?
      end

      chargeable
    end

    def find_by_processor_transaction_id!(processor_transaction_id)
      Charge.find_by!(processor_transaction_id:)
    rescue ActiveRecord::RecordNotFound
      Purchase.find_by!(stripe_transaction_id: processor_transaction_id)
    end

    def find_by_purchase_or_charge!(purchase: nil, charge: nil)
      raise ArgumentError, "Either purchase or charge must be present" if purchase.blank? && charge.blank?
      raise ArgumentError, "Only one of purchase or charge must be present" if purchase.present? && charge.present?
      return charge if charge.present?

      if purchase.uses_charge_receipt?
        # We always want to (re)send the charge receipt, if that's how it was originally sent.
        purchase.charge
      else
        purchase
      end
    end
  end

  def charged_purchases
    is_a?(Charge) ? purchases.non_free.to_a.reject { _1.is_free_trial_purchase? || _1.is_preorder_authorization? } : [self]
  end

  def successful_purchases
    is_a?(Charge) ? super : Purchase.where(id:)
  end

  def update_processor_fee_cents!(processor_fee_cents:)
    is_a?(Charge) ? super : update!(processor_fee_cents:)
  end

  def charged_amount_cents
    # Cannot use Charge#amount_cents because it is calculated before the purchases are being charged, so it may
    # include purchases that are not successful
    is_a?(Charge) ? successful_purchases.sum(&:total_transaction_cents) : total_transaction_cents
  end

  def charged_gumroad_amount_cents
    is_a?(Charge) ? gumroad_amount_cents : total_transaction_amount_for_gumroad_cents
  end

  def refundable_amount_cents
    is_a?(Charge) ? purchases.successful.sum(&:total_transaction_cents) : total_transaction_cents
  end

  def purchaser
    is_a?(Charge) ? order.purchaser : super
  end

  def orderable
    is_a?(Charge) ? order : self
  end

  def support_email
    unique_support_emails = successful_purchases.joins(:link).pluck("links.support_email").uniq

    if unique_support_emails.size == 1 && unique_support_emails.first.present?
      unique_support_emails.first
    else
      seller.support_or_form_email
    end
  end

  def unbundled_purchases
    @_unbundled_purchases ||=
      successful_purchases.map do |purchase|
        purchase.is_bundle_purchase? ? purchase.product_purchases : [purchase]
      end.flatten
  end

  # Used by ReceiptPresenter to render a different title for recurring subscription
  def is_recurring_subscription_charge
    is_a?(Charge) ? false : super
  end

  def taxable?
    is_a?(Charge) ? super : was_purchase_taxable?
  end

  def multi_item_charge?
    is_a?(Charge) ? super : false
  end

  def taxed_by_gumroad?
    is_a?(Charge) ? super : gumroad_tax_cents > 0
  end

  def external_id_for_invoice
    is_a?(Charge) ? super : external_id
  end

  def external_id_numeric_for_invoice
    is_a?(Charge) ? super : external_id_numeric.to_s
  end

  def subscription
    is_a?(Charge) ? nil : super
  end
end
