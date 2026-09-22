# frozen_string_literal: true

module Charge::Chargeable
  # How far back the payment-intent fallback below looks, in `charges.id`. The floor is
  # Stripe's 72-hour webhook retry window: a delivery retried on day three must still
  # resolve, so anything under ~300_000 ids at current volume would silently drop it.
  # 1M is ~12 days, and ~975k rows is a buffer-pool-resident scan instead of 8.35 GB.
  RECENT_CHARGE_ID_LOOKBACK = 1_000_000

  class << self
    # The :writing pin is declared for intent but does NOT take effect today: mysql2_proxy
    # routes per statement and its `roles_for` does not honour this stack entry, so these
    # reads still land on the worker replica. The id bound below is what actually protects
    # the fallback; do not drop it on the assumption that the pin is doing the work.
    def find_by_stripe_event(event)
      ApplicationRecord.connected_to(role: :writing) do
        chargeable = nil

        if event.charge_reference.to_s.starts_with?(Charge::COMBINED_CHARGE_PREFIX)
          chargeable ||= Charge.where(id: event.charge_reference.sub(Charge::COMBINED_CHARGE_PREFIX, "")).last
          chargeable ||= Charge.where(processor_transaction_id: event.charge_id).last if event.charge_id
          chargeable ||= recent_charge_by_payment_intent(event.processor_payment_intent_id) if event.processor_payment_intent_id.present?
        else
          chargeable = Purchase.find_by_external_id(event.charge_reference) if event.charge_reference
          # Refund events (refund.updated / refund.failed) carry no charge_reference — Stripe's
          # Refund object has no metadata and we don't retrieve the underlying charge for them —
          # so a refund on a combined charge lands in this branch instead of the CH- branch above.
          # Check Charge before Purchase: every purchase in a combined charge stores the shared
          # ch_ id in stripe_transaction_id (see Purchase#save_charge_data), so a purchase lookup
          # would match one arbitrary purchase and the event would miss the canonical Charge.
          # Same precedence as find_by_processor_transaction_id! below.
          chargeable ||= Charge.where(processor_transaction_id: event.charge_id).last if event.charge_id
          chargeable ||= Purchase.where(stripe_transaction_id: event.charge_id).last if event.charge_id
          chargeable ||= ProcessorPaymentIntent.where(intent_id: event.processor_payment_intent_id).last&.purchase if event.processor_payment_intent_id.present?
        end

        chargeable
      end
    end

    # `stripe_payment_intent_id` is unindexed, so an unbounded lookup scans all of `charges`.
    # This is only ever reached when the primary-key lookup on the CH- reference already
    # missed — i.e. the row is not visible to this connection — so it almost always returns
    # nil after paying for the whole scan. The id floor caps that miss at a short backward
    # PK range scan; a hit still stops at the first matching row, so the window costs nothing
    # when the charge is found.
    def recent_charge_by_payment_intent(payment_intent_id)
      max_id = Charge.maximum(:id).to_i
      Charge.where(stripe_payment_intent_id: payment_intent_id)
            .where(id: (max_id - RECENT_CHARGE_ID_LOOKBACK)..)
            .order(id: :desc)
            .first
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

  # Full refundable amount in the buyer-presentment currency, or nil for canonical
  # charges. Stripe denominates charge.refund.updated amounts in the charge currency,
  # so buyer-presentment refunds must be compared against this, not canonical USD cents.
  def presentment_refundable_amount_cents
    if is_a?(Charge)
      charge_presentment&.presentment_total_cents
    else
      purchase_presentment&.presentment_total_cents
    end
  end

  # Gumroad's own share of the charge, in the buyer-presentment currency, or nil for
  # canonical charges. Same reason as the sibling above: anything that has to express
  # Gumroad's cut in the currency Stripe actually charged (dispute flow-of-funds legs,
  # application-fee arithmetic) must read it from the presentment snapshot rather than
  # subtracting canonical USD cents from a non-USD Stripe amount.
  def presentment_gumroad_amount_cents
    if is_a?(Charge)
      charge_presentment&.presentment_gumroad_amount_cents
    else
      purchase_presentment&.presentment_gumroad_amount_cents
    end
  end

  # The currency the buyer was actually charged in, or nil when this charge was made in
  # canonical USD.
  def presentment_currency
    if is_a?(Charge)
      charge_presentment&.presentment_currency
    else
      purchase_presentment&.presentment_currency
    end
  end

  def purchaser
    is_a?(Charge) ? order.purchaser : super
  end

  def orderable
    is_a?(Charge) ? order : self
  end

  # Purchases render from themselves. The mailer checks this before the send claim.
  def receipt_renderable?
    is_a?(Charge) ? purchase_as_chargeable.present? : true
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
      successful_purchases.flat_map do |purchase|
        if !purchase.is_bundle_purchase?
          [purchase]
        elsif purchase.product_purchases.present?
          purchase.product_purchases
        elsif purchase.purchase_state.in?(Purchase::ALL_SUCCESS_STATES_INCLUDING_TEST)
          # Memberless successful bundles still need a receipt line (library does the same).
          [purchase]
        else
          []
        end
      end
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
