# frozen_string_literal: true

class Purchase::BaseService
  include AfterCommitEverywhere
  attr_accessor :purchase, :preorder

  protected
    def handle_purchase_success
      if purchase.free_purchase? && purchase.is_preorder_authorization?
        mark_preorder_authorized
        return
      end

      giftee_purchase = nil
      if purchase.is_gift_sender_purchase
        giftee_purchase = purchase.gift_given.giftee_purchase
        giftee_purchase.mark_gift_receiver_purchase_successful
      end

      create_subscription(giftee_purchase) if purchase.link.is_recurring_billing || purchase.is_installment_payment
      fix_later_charge_presentment

      purchase.update_balance_and_mark_successful!
      purchase.gift_given.mark_successful! if purchase.is_gift_sender_purchase
      purchase.seller.save_gumroad_day_timezone
      after_commit do
        ActivateIntegrationsWorker.perform_async(purchase.id)
      end
    end

    # Fixes the buyer-currency amount this subscription's later charges must reuse.
    #
    # Runs HERE, after #create_subscription, because this is the first moment both facts exist:
    # the charge has succeeded (so there is a real amount the buyer actually paid, recorded on
    # purchase_presentment) and the Subscription row exists to own the fixing. An earlier
    # attempt wrote this from Charge::PresentmentOrchestrator while the processor args were
    # being built, which could never work — purchase.subscription is still nil at that point,
    # so the write silently no-opped on every real signup (gumroad-private#1322).
    #
    # Reads the PRICE component rather than the total: tax and shipping are recomputed per
    # renewal from the member's current address, so freezing them would bill stale tax.
    def fix_later_charge_presentment
      subscription = purchase.subscription
      return if subscription.blank?
      # Only the charge that ESTABLISHES the subscription fixes the amount. A renewal reuses
      # the existing fixing, and a plan change appends its own row from the plan-change path.
      return unless purchase.is_original_subscription_purchase?
      # A gift is bought in the GIFTER's currency but the subscription belongs to the giftee
      # (#create_subscription builds it for them), so fixing the gifter's local amount would bill
      # the giftee in a currency they never chose, at a rate from a checkout they never saw.
      return if purchase.is_gift_sender_purchase?
      return if subscription.later_charge_presentments.exists?

      presentment = purchase.purchase_presentment
      return if presentment.blank?
      return unless presentment.presentment_price_cents.to_i.positive?
      return if presentment.presentment_currency.blank?

      # DIRECTION MATTERS. The rate lives on the CHARGE presentment (fx_rate is not a column on
      # purchase_presentments), and it is the Stripe quote's rate: US dollars per unit of the
      # presentment currency. LaterChargePresentment stores the reciprocal — units per US
      # dollar, the direction CurrencyHelper#get_rate returns and the direction
      # #usd_drift_cents does its arithmetic in. Storing fx_rate directly would invert every
      # drift figure computed from these rows.
      fx_rate = presentment.charge_presentment&.fx_rate
      return if fx_rate.blank? || !fx_rate.to_d.positive?

      subscription.later_charge_presentments.create!(
        processor: StripeChargeProcessor.charge_processor_id,
        presentment_currency: presentment.presentment_currency,
        presentment_price_cents: presentment.presentment_price_cents,
        # The canonical price this fixing is anchored to. A later charge compares the price it is
        # about to bill against this and falls back to dollars if the plan has moved since.
        canonical_price_cents: purchase.price_cents,
        signup_currency_units_per_usd: 1 / fx_rate.to_d,
        effective_from: Time.current
      )
    rescue ActiveRecord::RecordInvalid, ActiveRecord::RecordNotUnique => e
      # A missing fixing means later charges bill canonical US dollars — the pre-feature
      # behaviour — so it must never fail a charge the buyer already paid for.
      Rails.logger.warn("Could not fix later-charge presentment for purchase #{purchase.id}: #{e.message}")
      ErrorNotifier.notify(e, purchase_id: purchase.id)
    end

    def create_subscription(giftee_purchase)
      return if purchase.subscription.present?

      is_gift = purchase.is_gift_sender_purchase
      charge_occurrence_count =
        if purchase.is_installment_payment
          purchase.link.installment_plan.number_of_installments
        elsif purchase.link.duration_in_months.present?
          purchase.link.duration_in_months / BasePrice::Recurrence.number_of_months_in_recurrence(purchase.price.recurrence)
        end

      subscription = purchase.link.subscriptions.build(
        user: is_gift ? giftee_purchase.purchaser : purchase.purchaser,
        credit_card: is_gift ? nil : purchase.credit_card,
        is_test_subscription: purchase.is_test_purchase?,
        is_installment_plan: purchase.is_installment_payment,
        charge_occurrence_count:,
        free_trial_ends_at: purchase.is_free_trial_purchase? ? purchase.created_at + purchase.link.free_trial_duration : nil,
        business_vat_id: purchase.purchase_sales_tax_info&.business_vat_id
      )
      payment_option = PaymentOption.new(
        price: purchase.price,
        installment_plan: purchase.is_installment_payment ? purchase.link.installment_plan : nil
      )

      if purchase.is_installment_payment && purchase.link.installment_plan.present?
        total_price = purchase.total_price_before_installments
        if total_price.present? && total_price > 0
          payment_option.build_installment_plan_snapshot(
            number_of_installments: purchase.link.installment_plan.number_of_installments,
            recurrence: purchase.link.installment_plan.recurrence,
            total_price_cents: total_price
          )
        end
      end

      subscription.payment_options << payment_option
      subscription.save!
      subscription.purchases << [purchase, giftee_purchase].compact
    end

    def handle_purchase_failure
      mark_items_failed
    end

    def mark_items_failed
      if purchase.is_preorder_authorization?
        mark_preorder_failed
      else
        purchase.mark_failed
      end

      if purchase.is_gift_sender_purchase
        purchase.gift_given.mark_failed!
        purchase.gift_given.giftee_purchase&.mark_gift_receiver_purchase_failed!
      end

      subscription = purchase.subscription
      if subscription&.is_resubscription_pending_confirmation?
        subscription.unsubscribe_and_fail!
        subscription.update_flag!(:is_resubscription_pending_confirmation, false, true)
      elsif purchase.is_upgrade_purchase?
        new_original_purchase = subscription.original_purchase
        previous_original_purchase = subscription.purchases.is_archived_original_subscription_purchase.last
        new_original_purchase.update_flag!(:is_archived_original_subscription_purchase, true, true)
        previous_original_purchase.update_flag!(:is_archived_original_subscription_purchase, false, true)
        subscription.last_payment_option.update!(price: previous_original_purchase.price) if previous_original_purchase.price.present?
      end
    end

    def mark_preorder_authorized
      if purchase.is_test_purchase?
        purchase.mark_test_preorder_successful!
        preorder.mark_test_authorization_successful!
      else
        purchase.mark_preorder_authorization_successful!
        preorder.mark_authorization_successful!
      end
    end

    def mark_preorder_failed
      if purchase.is_test_purchase?
        purchase.mark_test_preorder_successful!
        preorder&.mark_test_authorization_successful!
      else
        purchase.mark_preorder_authorization_failed
        preorder&.mark_authorization_failed!
      end
    end
end
