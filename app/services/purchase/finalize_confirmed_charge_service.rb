# frozen_string_literal: true

# Finalizes a single client-confirm purchase from an already-retrieved PaymentIntent.
#
# Unlike Purchase::ConfirmService, it does NOT confirm the intent because the browser already did. It is
# handed a retrieve-only charge intent so a `processing` intent is never re-confirmed (which Stripe
# rejects). Idempotent: a purchase that another trigger (AJAX, return page, or webhook) already
# finalized is a no-op, so fulfillment happens exactly once.
class Purchase::FinalizeConfirmedChargeService < Purchase::BaseService
  def initialize(purchase:, charge_intent:)
    @purchase = purchase
    @preorder = purchase.preorder
    @charge_intent = charge_intent
  end

  # with_lock serializes AJAX, abandonment-worker, and webhook finalizers so only one can fulfill
  # the captured charge.
  def perform
    purchase.with_lock do
      if purchase.successful?
        nil
      elsif !purchase.in_progress?
        "There is a temporary problem, please try again (your card was not charged)."
      elsif charge_intent.succeeded?
        finalize_successful_charge
      elsif charge_intent.processing?
        purchase.update!(stripe_status: StripeIntentStatus::PROCESSING)
        :pending
      else
        fail_purchase
      end
    end
  end

  private
    attr_reader :charge_intent

    def finalize_successful_charge
      purchase.charge_intent = charge_intent
      assign_confirmed_card_presentation(charge_intent.charge)
      purchase.save_charge_data(charge_intent.charge)

      if purchase.errors.present?
        error_message = purchase.errors.full_messages[0]
        handle_purchase_failure
        return error_message
      end

      handle_purchase_success
      nil
    end

    # Client-confirm checkout never builds a server-side chargeable, so derive
    # card_visual/type/country from the confirmed charge. Expiry, fingerprint, and
    # processor id are handled by #save_charge_data.
    def assign_confirmed_card_presentation(processor_charge)
      return if processor_charge.card_last4.blank?

      purchase.card_visual = ChargeableVisual.build_visual(processor_charge.card_last4, processor_charge.card_number_length)
      purchase.card_type = processor_charge.card_type
      # Only overwrite the previewed card country when Stripe returns a confirmed value; null would
      # clobber card_country while leaving card_country_source as "stripe".
      purchase.card_country = processor_charge.card_country if processor_charge.card_country.present?
    end

    def fail_purchase
      purchase.errors.add(:base, "Sorry, something went wrong.") if purchase.errors.empty?
      error_message = purchase.errors.full_messages[0]
      handle_purchase_failure
      error_message
    end
end
