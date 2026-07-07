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
      return stripe_transaction_id unless is_a?(Charge)
      return processor_transaction_id if processor_transaction_id.present?

      disputed_purchases.one? ? disputed_purchases.first.stripe_transaction_id : nil
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
      ErrorNotifier.notify("Invalid charge event received for failed #{self.class.name} #{external_id} - " \
                      "received reversal notification with ID #{event.charge_event_id}")
      return
    end

    if event.flow_of_funds.nil? && event.charge_processor_id != StripeChargeProcessor.charge_processor_id
      event.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(Currency::USD, -disputed_amount_cents)
    end

    dispute = find_or_build_dispute(event)

    if dispute.formalized? && dispute.formalized_side_effects_finished_at.nil?
      # The first webhook attempt marked the dispute formalized but crashed partway through
      # the side effects (balance decrement, payout pause, notifications). The processor
      # re-delivers the webhook; resume the remaining work instead of skipping it.
      # Every step inside is guarded so already-completed work is not applied twice.
      perform_dispute_formalized_side_effects!(event, dispute)
      return
    end

    unless dispute.initiated? || dispute.created?
      # The dispute is already past its initial state AND its side effects finished (or it has
      # since been won/lost), which means this event is a replay — the payment processor
      # re-delivers the webhook when an earlier attempt failed partway through. Refund-policy
      # enforcement is enqueued late in the first attempt (after the dispute is marked
      # formalized), so a failure at that point — say, a Redis outage during the Sidekiq
      # enqueue — would otherwise leave the seller's enforcement check unscheduled forever,
      # because the replay returns here without reaching that code. Re-enqueueing on every
      # replay is safe: the job no-ops once the seller is already enforced (or doesn't cross
      # the dispute-rate thresholds), so duplicates do nothing.
      disputed_purchases.each { |purchase| EnforceRefundPolicyForSellerJob.perform_async(purchase.id) }
      return
    end

    mark_as_disputed!(disputed_at: event.created_at)

    disputed_purchases.each do |purchase|
      # A replay that crashed after creating this event but before mark_formalized! re-enters
      # this normal path (the dispute is still in its initial state), so skip purchases that
      # already have their chargeback event to avoid duplicate analytics rows.
      next if Event.where(purchase_id: purchase.id, event_name: "chargeback").exists?

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

    perform_dispute_formalized_side_effects!(event, dispute)
  end

  def resolve_pending_dispute_evidence_if_any!(error_message)
    evidence = dispute.dispute_evidence
    return if evidence.nil? || evidence.resolved?

    evidence.update_as_resolved!(
      resolution: DisputeEvidence::RESOLUTION_REJECTED,
      error_message:
    )
  end

  def handle_event_dispute_won!(event)
    unless disputed_purchases.any?(&:successful?)
      ErrorNotifier.notify("Invalid charge event received for failed #{self.class.name} #{external_id} - " \
                      "received reversal won notification with ID #{event.charge_event_id}")
      return
    end

    unless disputed?
      ErrorNotifier.notify("Invalid charge event received for successful #{self.class.name} #{external_id} - " \
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
      purchase.update!(chargeback_reversed: true)
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

    resolve_pending_dispute_evidence_if_any!("Dispute closed (won) before evidence was submitted.")
  end

  def handle_event_dispute_lost!(event)
    dispute = find_or_build_dispute(event)
    dispute.mark_lost!

    # PayPal can resolve a dispute as non-seller-favour while only partially refunding the buyer
    # (e.g. INCORRECT_AMOUNT settled with a partial refund). The purchase stays successful and
    # partially_refunded, so the chargeback flag set at formalization must be lifted to restore access.
    # Scoped to PayPal because Stripe-lost disputes pull the full disputed amount via the bank,
    # so a pre-dispute partial refund there does not mean the buyer is net-paying.
    disputed_purchases.each do |purchase|
      next unless purchase.charge_processor_id == PaypalChargeProcessor.charge_processor_id
      next unless purchase.successful?
      next if purchase.stripe_refunded
      next unless purchase.stripe_partially_refunded

      purchase.update!(chargeback_reversed: true)
      purchase.mark_giftee_purchase_as_chargeback_reversed if purchase.is_gift_sender_purchase
      purchase.mark_product_purchases_as_chargeback_reversed!
    end

    resolve_pending_dispute_evidence_if_any!("Dispute closed (lost) before evidence was submitted.")

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

  private
    # Everything that must happen after a dispute is formalized: seller balance decrement,
    # subscription cancellation, chargeback flags, payout pause, buyer block, notifications.
    # Runs on the first delivery and again on webhook replay if a previous attempt crashed
    # before writing formalized_side_effects_finished_at, so each step is either guarded here
    # or idempotent on its own.
    def perform_dispute_formalized_side_effects!(event, dispute)
      disputed_purchases.each do |purchase|
        flow_of_funds = build_flow_of_funds(event.flow_of_funds, purchase)
        # Replay-safe without a guard here: decrement_balance_for_refund_or_chargeback! checks
        # seller_balance_update_eligible? internally and returns early once the purchase already
        # has a purchase_chargeback_balance, so a replay never debits the seller twice.
        purchase.decrement_balance_for_refund_or_chargeback!(flow_of_funds, dispute:)

        if purchase.link.is_recurring_billing
          subscription = Subscription.find_by(id: purchase.subscription_id)
          # Only cancel a live subscription: re-cancelling one that a previous attempt already
          # deactivated would re-fire the cancellation webhooks and customer emails on replay.
          # The review exclusion stays inside this guard because it is tied to the cancellation.
          if subscription.present? && subscription.deactivated_at.nil?
            subscription.cancel_effective_immediately!(by_buyer: true)
            subscription.original_purchase.update!(should_exclude_product_review: true) if subscription.should_exclude_product_review_on_charge_reversal?
          end
        end

        purchase.enqueue_update_sales_related_products_infos_job(false)
        purchase.mark_giftee_purchase_as_chargeback if purchase.is_gift_sender_purchase

        # No replay guard needed for these writes: the same event always carries the same
        # date and reason, so rewriting them is a no-op.
        purchase.chargeback_date = event.created_at
        purchase.chargeback_reason = event.extras.try(:[], :reason)
        purchase.save!

        purchase.mark_product_purchases_as_chargedback!

        # pause_payouts_for_seller_based_on_chargeback_rate! and block_buyer_based_on_chargeback_count!
        # are both idempotent (they recompute from current data and re-apply the same state),
        # so replays can safely call them again.
        purchase.pause_payouts_for_seller_based_on_chargeback_rate!
        # Enforcement runs as a background job rather than inline: the dispute was already
        # marked formalized above, so an inline failure here would otherwise be skipped on
        # webhook retry. The job gets its own Sidekiq retries and the enforcement method is
        # idempotent.
        EnforceRefundPolicyForSellerJob.perform_async(purchase.id)
        purchase.block_buyer_based_on_chargeback_count!
      end

      dispute_evidence = create_dispute_evidence_if_needed!
      # Don't re-stamp seller_contacted_at on replay: it anchors the 72-hour evidence-submission
      # window, and moving it forward would silently extend the seller's deadline.
      dispute_evidence.update_as_seller_contacted! if dispute_evidence.present? && !dispute_evidence.seller_contacted?

      # No per-step guards from here down: the completion marker written at the end prevents
      # any re-delivery from reaching this code, except for a crash inside the tiny window
      # between these enqueues and the marker write — that degrades to at-least-once
      # email/webhook delivery, which is normal for crash-retry semantics.
      ContactingCreatorMailer.chargeback_notice(dispute.id).deliver_later
      AdminMailer.chargeback_notify(dispute.id).deliver_later
      CustomerLowPriorityMailer.chargeback_notice_to_customer(dispute.id).deliver_later(wait: 5.seconds)

      disputed_purchases.each do |purchase|
        # Check for low balance and put the creator on probation
        LowBalanceFraudCheckWorker.perform_in(5.seconds, purchase.id)

        PostToPingEndpointsWorker.perform_in(5.seconds, purchase.id, purchase.url_parameters, ResourceSubscription::DISPUTE_RESOURCE_NAME)
      end

      FightDisputeJob.perform_async(dispute.id) if dispute_evidence.present?

      # Completion marker: a replayed webhook only re-runs these side effects while this is nil.
      dispute.update!(formalized_side_effects_finished_at: Time.current)
    end
end
