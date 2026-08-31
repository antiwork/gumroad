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
      elsif charge_intent.awaiting_customer_initiated_payment?
        # Pix: Stripe gave the buyer a QR code / copy-paste key to pay in their banking app, and
        # the intent stays in requires_action until they do. The browser's confirm call returning
        # only means the buyer closed the QR modal, so failing the purchase here would kill a
        # payment they can still make (and, once they paid, would leave the money unmatched to any
        # purchase). Keep it in progress and report it as pending; the payment_intent.succeeded /
        # payment_intent.payment_failed webhooks decide the real outcome, and the abandonment
        # worker only cancels intents that are neither succeeded nor processing after the SCA
        # window — see the Pix expiry note there.
        purchase.update!(stripe_status: StripeIntentStatus::REQUIRES_ACTION)
        :pending
      else
        fail_purchase
      end
    end
  rescue StandardError => e
    raise unless charge_intent.succeeded?

    # Stripe has captured the payment, so a local invariant failure must not return a resubmittable
    # error or transition the purchase to failed. The row stays recoverable by status sync.
    ErrorNotifier.notify(
      e,
      context: {
        purchase_id: purchase.id,
        payment_intent_id: charge_intent.payment_intent.id,
      }
    )
    purchase.reload.update_column(:stripe_status, StripeIntentStatus::SUCCESS)
    :pending
  end

  private
    attr_reader :charge_intent

    def finalize_successful_charge
      purchase.charge_intent = charge_intent
      assign_confirmed_card_presentation(charge_intent.charge)
      # Same missing-settlement deferral as Order::ChargeService / confirm_charge_intent!.
      # Raising inside with_lock rolls back the stripe_transaction_id the retry jobs key on.
      charge_data_saved = purchase.save_charge_data(
        charge_intent.charge,
        allow_missing_flow_of_funds: purchase.processor_settlement_deferrable?
      )

      if charge_data_saved == false
        enqueue_processor_settlement_finalizer
        return :pending
      end

      persist_recurring_payment_method!

      if purchase.errors.present?
        error_message = purchase.errors.full_messages[0]
        handle_purchase_failure
        return error_message
      end

      handle_purchase_success
      nil
    end

    def enqueue_processor_settlement_finalizer
      charge = purchase.charge
      if charge.present?
        FinalizeBuyerPresentmentChargeJob.perform_in(FinalizeBuyerPresentmentChargeJob::INITIAL_DELAY, charge.id)
      else
        FinalizeBuyerPresentmentPurchaseJob.perform_in(FinalizeBuyerPresentmentPurchaseJob::INITIAL_DELAY, purchase.id)
      end
    end

    # Persist the reusable method before creating the subscription. Any missing invariant rolls
    # back fulfillment so a retry cannot leave a live subscription without a renewable instrument.
    def persist_recurring_payment_method!
      return unless purchase.is_original_subscription_purchase?
      return unless purchase.link.is_recurring_billing?
      return if purchase.is_installment_payment? || purchase.is_gift_sender_purchase?
      return if purchase.credit_card.present?

      credit_card = CreditCard.create_from_client_confirmed_intent!(
        payment_intent: charge_intent.payment_intent,
        processor_charge: charge_intent.charge,
        merchant_account: purchase.merchant_account
      )
      purchase.update!(credit_card:)
      # save_charge_data ran before this client-confirmed card existed, so repeat the
      # observability-only Indian-card check now that it can see the saved mandate source.
      purchase.check_indian_card_mandate_was_registered(charge_intent.charge)
    end

    # Client-confirm checkout never builds a server-side chargeable, so derive
    # card_visual/type/country from the confirmed charge. Expiry, fingerprint, and
    # processor id are handled by #save_charge_data.
    def assign_confirmed_card_presentation(processor_charge)
      # Inline non-card methods (e.g. Link) expose no last4/visual, but still carry a
      # card_type/country worth persisting for receipts and analytics.
      if processor_charge.card_last4.blank?
        purchase.card_type = processor_charge.card_type if processor_charge.card_type.present?
        purchase.card_country = processor_charge.card_country if processor_charge.card_country.present?
        return
      end

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
