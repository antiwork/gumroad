# frozen_string_literal: true

class FailAbandonedPurchaseWorker
  include Sidekiq::Job, StripeErrorHandler
  sidekiq_options retry: 5, queue: :default

  attr_reader :purchase

  def perform(purchase_id)
    @purchase = Purchase.find(purchase_id)

    return unless purchase.in_progress?

    # Guard against the job executing too early
    if purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA > Time.current
      FailAbandonedPurchaseWorker.perform_at(purchase.created_at + ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase_id)
      return
    end

    with_stripe_error_handler do
      merchant_account = purchase.merchant_account
      return if merchant_account&.is_a_stripe_connect_account? && merchant_account.charge_processor_merchant_id.blank?

      if purchase.processor_payment_intent_id.present?
        payment_intent = if merchant_account&.is_a_stripe_connect_account?
          Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::PaymentIntent.retrieve(purchase.processor_payment_intent_id)
        end
        return if reschedule_for_outstanding_pix_key(payment_intent)

        cancel_charge_intent unless payment_intent.status == StripeIntentStatus::PROCESSING
      elsif purchase.processor_setup_intent_id.present?
        setup_intent = if merchant_account&.is_a_stripe_connect_account?
          Stripe::SetupIntent.retrieve(purchase.processor_setup_intent_id, { stripe_account: merchant_account.charge_processor_merchant_id })
        else
          Stripe::SetupIntent.retrieve(purchase.processor_setup_intent_id)
        end
        if setup_intent.status != StripeIntentStatus::PROCESSING && shared_setup_intent_still_needed?
          FailAbandonedPurchaseWorker.perform_in(ChargeProcessor::TIME_TO_COMPLETE_SCA, purchase.id)
          return
        end
        cancel_setup_intent unless setup_intent.status == StripeIntentStatus::PROCESSING
      else
        raise "Expected purchase #{purchase.id} to have either a processor_payment_intent_id or processor_setup_intent_id present"
      end
    end
  end

  private
    # A Pix buyer is given a QR code / copy-paste key to pay in their banking app, and the intent
    # sits in requires_action until they do. That key can legitimately outlive the SCA window this
    # worker runs on (Order::PreparePaymentIntentService::PIX_EXPIRES_AFTER_SECONDS), so cancelling
    # the intent here would kill a payment the buyer can still make — and, if they paid a moment
    # later, leave the money with no purchase to attach it to. Wait for the key's own expiry
    # instead: after it, the intent can no longer be paid and this worker cancels it as usual.
    # Stripe also emits payment_intent.payment_failed on expiry, so the purchase resolves either
    # way; this only stops us from pre-empting the buyer.
    def reschedule_for_outstanding_pix_key(payment_intent)
      return false unless payment_intent.status == StripeIntentStatus::REQUIRES_ACTION

      next_action = payment_intent.next_action
      return false unless next_action&.type.in?(StripeIntentStatus::ASYNCHRONOUS_CUSTOMER_INITIATED_ACTION_TYPES)

      expires_at = next_action[next_action.type.to_sym]&.[](:expires_at)
      # No expiry to wait for (Stripe omits it in some test-mode simulations) — fall through and
      # treat the intent like any other abandoned one rather than rescheduling forever.
      return false if expires_at.blank?

      expiry = Time.zone.at(expires_at.to_i)
      return false if expiry <= Time.current

      FailAbandonedPurchaseWorker.perform_at(expiry + 1.minute, purchase.id)
      true
    end

    def cancel_charge_intent
      purchase.cancel_charge_intent!
    rescue ChargeProcessorError
      charge_intent = ChargeProcessor.get_charge_intent(purchase.merchant_account, purchase.processor_payment_intent_id)

      # Ignore the error if:
      # - charge intent succeeded (user completed SCA in the meanwhile)
      # - charge intent has been cancelled (by a parallel purchase)
      # In both these cases the purchase will transition to a successful or failed state.
      #
      # Raise all other (unexpected) errors.
      #
      # A client-confirm charge that succeeded but was never finalized (browser disappeared) stays
      # in_progress here; the Phase 2 PaymentIntent webhook is the source of truth that finalizes it.
      raise unless charge_intent&.succeeded? || charge_intent&.canceled?
    end

    # Only siblings still inside their own SCA window should block cancel. Older
    # in_progress siblings are abandoned too; cancel_setup_intent fails them together
    # with this purchase so they cannot stay stuck after the shared intent is canceled.
    def shared_setup_intent_still_needed?
      Purchase.where(processor_setup_intent_id: purchase.processor_setup_intent_id)
              .where.not(id: purchase.id)
              .where(purchase_state: "in_progress")
              .where("created_at > ?", ChargeProcessor::TIME_TO_COMPLETE_SCA.ago)
              .exists?
    end

    # Cancelling a shared SetupIntent must fail every in_progress purchase that still
    # points at it. Otherwise a newer sibling's worker can cancel the intent while an
    # older sibling (past its own SCA window, so excluded from shared_setup_intent_still_needed?)
    # stays in_progress forever when it later sees the already-canceled intent.
    def cancel_setup_intent
      ChargeProcessor.cancel_setup_intent!(purchase.merchant_account, purchase.processor_setup_intent_id)
      fail_in_progress_purchases_sharing_setup_intent!
    rescue ChargeProcessorError
      setup_intent = ChargeProcessor.get_setup_intent(purchase.merchant_account, purchase.processor_setup_intent_id)

      # Ignore the error if:
      # - setup intent succeeded (user completed SCA in the meanwhile) — confirm will finish it
      # - setup intent has been cancelled (by a parallel purchase / sibling worker)
      #
      # Raise all other (unexpected) errors.
      raise unless setup_intent&.succeeded? || setup_intent&.canceled?

      # A parallel cancel may have left this purchase (and shared-SI siblings) in_progress.
      fail_in_progress_purchases_sharing_setup_intent! if setup_intent&.canceled?
    end

    def fail_in_progress_purchases_sharing_setup_intent!
      setup_intent_id = purchase.processor_setup_intent_id
      return if setup_intent_id.blank?

      # Prefer the order association (indexed via order_purchases) so we do not scan the
      # unindexed processor_setup_intent_id column across the whole purchases table.
      # Always include this purchase itself so a delayed/retried job cannot cancel the
      # SetupIntent and then age-filter the target out of cleanup.
      siblings = if (order = purchase.order)
        order.purchases.where(processor_setup_intent_id: setup_intent_id, purchase_state: "in_progress")
      else
        Purchase.where(processor_setup_intent_id: setup_intent_id, purchase_state: "in_progress")
                .where("id = ? OR created_at > ?", purchase.id, (ChargeProcessor::TIME_TO_COMPLETE_SCA * 2).ago)
      end

      siblings.find_each do |sibling|
        sibling.with_lock do
          next unless sibling.in_progress?

          Purchase::MarkFailedService.new(sibling).perform
        end
      end
    end
end
