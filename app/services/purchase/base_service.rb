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

      purchase.update_balance_and_mark_successful!
      purchase.gift_given.mark_successful! if purchase.is_gift_sender_purchase
      purchase.seller.save_gumroad_day_timezone
      after_commit do
        ActivateIntegrationsWorker.perform_async(purchase.id)
      end
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
        free_trial_ends_at: purchase.is_free_trial_purchase? ? purchase.created_at + purchase.link.free_trial_duration : nil
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
