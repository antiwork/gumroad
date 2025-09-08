# frozen_string_literal: true

module Charge::Disputable
  extend ActiveSupport::Concern
  include CurrencyHelper

  included do
    has_one :dispute

    def charge_processor
      is_a?(Charge) ? processor : charge_processor_id
    end

    def charge_processor_transaction_id
      is_a?(Charge) ? processor_transaction_id : stripe_transaction_id
    end

    def purchase_for_dispute_evidence
      @_purchase_for_dispute_evidence ||= if multiple_purchases?
        purchases_with_a_refund_policy = disputed_purchases.select { _1.purchase_refund_policy.present? }
        subscription_purchases = disputed_purchases.select { _1.subscription.present? }
        subscription_purchases_with_a_refund_policy = purchases_with_a_refund_policy & subscription_purchases

        selected_purchases = subscription_purchases_with_a_refund_policy.presence
        selected_purchases ||= if dispute&.reason == Dispute::REASON_SUBSCRIPTION_CANCELED
          subscription_purchases.presence || purchases_with_a_refund_policy.presence
        else
          purchases_with_a_refund_policy.presence || subscription_purchases.presence
        end

        selected_purchases ||= disputed_purchases

        selected_purchases.sort_by(&:total_transaction_cents).last
      else
        disputed_purchases.first
      end
    end

    def first_product_without_refund_policy
      disputed_purchases.find { !_1.link.product_refund_policy_enabled? }&.link
    end

    def disputed_amount_cents
      is_a?(Charge) ? amount_cents : total_transaction_cents
    end

    def formatted_disputed_amount
      formatted_dollar_amount(disputed_amount_cents)
    end

    def customer_email
      purchase_for_dispute_evidence.email
    end

    def disputed_purchases
      is_a?(Charge) ? purchases.to_a : [self]
    end

    def multiple_purchases?
      disputed_purchases.count > 1
    end

    def dispute_balance_date
      purchase_for_dispute_evidence.succeeded_at.to_date
    end

    def mark_as_disputed!(disputed_at:)
      is_a?(Charge) ? update!(disputed_at:) : update!(chargeback_date: disputed_at)
    end

    def mark_as_dispute_reversed!(dispute_reversed_at:)
      is_a?(Charge) ? update!(dispute_reversed_at:) : update!(chargeback_reversed: true)
    end

    def disputed?
      is_a?(Charge) ? disputed_at.present? : chargeback_date.present?
    end

    def build_flow_of_funds(event_flow_of_funds, purchase)
      multiple_purchases? ?
          purchase.build_flow_of_funds_from_combined_charge(event_flow_of_funds) :
          event_flow_of_funds
    end
  end

  def handle_event_dispute_formalized!(event)
    unless disputed_purchases.any?(&:successful?)
      Bugsnag.notify("Invalid charge event received for failed #{self.class.name} #{external_id} - " \
                      "received reversal notification with ID #{event.charge_event_id}")
      return
    end

    if event.flow_of_funds.nil? && event.charge_processor_id != StripeChargeProcessor.charge_processor_id
      event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -disputed_amount_cents)
    end

    dispute = find_or_build_dispute(event)

    return unless dispute.initiated? || dispute.created?

    mark_as_disputed!(disputed_at: event.created_at)

    disputed_purchases.each do |purchase|
      purchase_event = Event.where(purchase_id: purchase.id, event_name: "purchase").last
      if purchase_event.present?
        Event.create(
          event_name: "chargeback",
          purchase_id: purchase_event.purchase_id,
          browser_fingerprint: purchase_event.browser_fingerprint,
          ip_address: purchase_event.ip_address
        )
      end
    end

    dispute.mark_formalized!

    disputed_purchases.each do |purchase|
      flow_of_funds = build_flow_of_funds(event.flow_of_funds, purchase)
      purchase.decrement_balance_for_refund_or_chargeback!(flow_of_funds, dispute:)

      if purchase.link.is_recurring_billing
        subscription = Subscription.find_by(id: purchase.subscription_id)
        subscription.cancel_effective_immediately!(by_buyer: true)
        subscription.original_purchase.update!(should_exclude_product_review: true) if subscription.should_exclude_product_review_on_charge_reversal?
      end

      purchase.enqueue_update_sales_related_products_infos_job(false)
      purchase.mark_giftee_purchase_as_chargeback if purchase.is_gift_sender_purchase

      purchase.chargeback_date = event.created_at
      purchase.chargeback_reason = event.extras.try(:[], :reason)
      purchase.save!

      purchase.mark_product_purchases_as_chargedback!

      purchase.pause_payouts_for_seller_based_on_chargeback_rate!
    end

    dispute_evidence = create_dispute_evidence_if_needed!
    dispute_evidence&.update_as_seller_contacted!

    ContactingCreatorMailer.chargeback_notice(dispute.id).deliver_later
    AdminMailer.chargeback_notify(dispute.id).deliver_later
    CustomerLowPriorityMailer.chargeback_notice_to_customer(dispute.id).deliver_later(wait: 5.seconds)

    disputed_purchases.each do |purchase|
      # Check for low balance and put the creator on probation
      LowBalanceFraudCheckWorker.perform_in(5.seconds, purchase.id)

      PostToPingEndpointsWorker.perform_in(5.seconds, purchase.id, purchase.url_parameters, ResourceSubscription::DISPUTE_RESOURCE_NAME)
    end

    FightDisputeJob.perform_async(dispute_evidence.dispute.id) if dispute_evidence.present?
  end

  def handle_event_dispute_won!(event)
    unless disputed_purchases.any?(&:successful?)
      Bugsnag.notify("Invalid charge event received for failed #{self.class.name} #{external_id} - " \
                      "received reversal won notification with ID #{event.charge_event_id}")
      return
    end

    unless disputed?
      Bugsnag.notify("Invalid charge event received for successful #{self.class.name} #{external_id} - " \
                      "received reversal won notification with ID #{event.charge_event_id} but was not disputed.")
      return
    end

    if event.flow_of_funds.nil? && event.charge_processor_id != StripeChargeProcessor.charge_processor_id
      event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, disputed_amount_cents)
    end

    dispute = find_or_build_dispute(event)
    dispute.mark_won!
    mark_as_dispute_reversed!(dispute_reversed_at: event.created_at)

    disputed_purchases.each do |purchase|
      purchase.chargeback_reversed = true
      purchase.mark_giftee_purchase_as_chargeback_reversed if purchase.is_gift_sender_purchase

      purchase.mark_product_purchases_as_chargeback_reversed!

      if purchase.link.is_recurring_billing?
        logger.info("Chargeback event won; re-activating subscription: #{purchase.subscription_id}")
        subscription = Subscription.find_by(id: purchase.subscription_id)
        terminated_or_scheduled_for_termination = subscription.termination_date.present?
        subscription.resubscribe!
        subscription.send_restart_notifications!(Subscription::ResubscriptionReason::PAYMENT_ISSUE_RESOLVED) if terminated_or_scheduled_for_termination
      end

      unless purchase.refunded?
        purchase.enqueue_update_sales_related_products_infos_job
        flow_of_funds = build_flow_of_funds(event.flow_of_funds, purchase)
        purchase.create_credit_for_dispute_won!(flow_of_funds)
        PostToPingEndpointsWorker.perform_in(5.seconds, purchase.id, purchase.url_parameters, ResourceSubscription::DISPUTE_WON_RESOURCE_NAME)
      end
    end

    ContactingCreatorMailer.chargeback_won(dispute.id).deliver_later unless disputed_purchases.all?(&:refunded?)
  end

  def handle_event_dispute_lost!(event)
    dispute = find_or_build_dispute(event)
    dispute.mark_lost!
    return unless first_product_without_refund_policy.present?

    ContactingCreatorMailer.chargeback_lost_no_refund_policy(dispute.id).deliver_later
  end

  def find_or_build_dispute(event)
    self.dispute ||= build_dispute(
      charge_processor_id: charge_processor,
      charge_processor_dispute_id: event.extras.try(:[], :charge_processor_dispute_id),
      reason: event.extras.try(:[], :reason),
      event_created_at: event.created_at,
    )
  end

  def create_dispute_evidence_if_needed!
    return dispute.dispute_evidence if dispute.dispute_evidence.present?
    return unless disputed?
    return unless eligible_for_dispute_evidence?

    DisputeEvidence.create_from_dispute!(dispute)
  end

  def eligible_for_dispute_evidence?
    return false unless charge_processor == StripeChargeProcessor.charge_processor_id
    return false if merchant_account&.is_a_stripe_connect_account?
    true
  end

  def fight_chargeback
    dispute_evidence = dispute.dispute_evidence

    ChargeProcessor.fight_chargeback(charge_processor, charge_processor_transaction_id, dispute_evidence)
  end
end
