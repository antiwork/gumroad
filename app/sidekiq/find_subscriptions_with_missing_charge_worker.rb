# frozen_string_literal: true

class FindSubscriptionsWithMissingChargeWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :low
  BATCHES_SCHEDULE_MARGIN_IN_MINUTES = 20

  def perform(batch_number = nil)
    if batch_number.nil?
      10.times { |i| self.class.perform_in(i * BATCHES_SCHEDULE_MARGIN_IN_MINUTES * 60, i) }
      return
    end

    susbcriptions = Subscription
      .not_is_test_subscription
      .where(deactivated_at: nil)
      .where("subscriptions.id % 10 = ?", batch_number)
      .includes(link: :user)
    susbcriptions.find_in_batches do |subscriptions|
      subscriptions.reject! { |subscription| subscription.link.user.suspended? || subscription.has_a_charge_in_progress? }
      next if subscriptions.empty?

      subscriptions = Subscription.where(id: subscriptions.map(&:id)).includes(:original_purchase).to_a
      subscriptions.reject! { |subscription| zero_price?(subscription) }
      next if subscriptions.empty?

      subscriptions = Subscription.includes(:last_successful_purchase, last_payment_option: :price).where(id: subscriptions.map(&:id)).to_a
      subscriptions.reject! do |subscription|
        subscription.last_successful_purchase.blank? || subscription.seconds_overdue_for_charge < 75.minutes
      end

      subscriptions.each do |subscription|
        Rails.logger.info("Found potentially missing charge for subscription #{subscription.id}")
        # A completed Indian-mandate restart or recovery whose charge enqueue never landed. Ignoring consecutive
        # failures would fail the membership on the very failure it just recovered from, so charge it as the job does.
        if subscription.indian_card_mandate_recovery_pending? && !subscription.renewal_disabled_due_to_indian_card_mandate?
          CompleteIndianCardMandateJob.perform_async(subscription.id)
          next
        end
        RecurringChargeWorker.perform_async(subscription.id, true)
      end
    end

    # After the charge scan: a notice is not worth delaying money recovery for.
    redrive_indian_card_mandate_restart_notices(batch_number)
  end

  private
    # Priced as RecurringChargeWorker will charge it, so a restart's persisted pricing context is not rejected (or
    # admitted) on the account's default price. A missing pricing buyer takes the worker's terminal path. Any failure
    # here is reported and skips only this subscription (true), so one bad row cannot abort the money-recovery scan.
    def zero_price?(subscription)
      pricing = subscription.indian_card_mandate_restart_charge_pricing
      subscription.current_subscription_price_cents(**pricing) == 0
    rescue Subscription::PricingBuyerMissing => e
      fail_for_missing_pricing_buyer(subscription, e.buyer_id)
      true
    rescue StandardError => e
      ErrorNotifier.notify(e, subscription_id: subscription.id)
      true
    end

    # Separate from `zero_price?` because a sibling `rescue` clause does not catch what another one raises.
    def fail_for_missing_pricing_buyer(subscription, buyer_id)
      subscription.fail_for_missing_pricing_buyer!(buyer_id)
    rescue StandardError => e
      ErrorNotifier.notify(e, subscription_id: subscription.id)
    end

    # Starts from the indexed `notice_owed` column, not the live-membership relation: an abandonment notice is
    # typically owed on an ended or deactivated membership, which that relation never visits. Notices past the
    # retention window are dropped rather than redriven, so an undeliverable one cannot loop forever; each row is
    # isolated so neither a stale nor a failing notice holds up the others.
    def redrive_indian_card_mandate_restart_notices(batch_number)
      owed = Subscription
        .where(indian_card_mandate_restart_notice_owed: true)
        .where("subscriptions.id % 10 = ?", batch_number)
        .select(:id)
      cutoff = Subscription::INDIAN_CARD_MANDATE_RESTART_NOTICE_RETENTION.ago

      owed.where("indian_card_mandate_restart_notice_recorded_at >= ?", cutoff).find_each do |subscription|
        DeliverIndianCardMandateRestartNoticesJob.perform_async(subscription.id)
      rescue StandardError => e
        ErrorNotifier.notify(e, subscription_id: subscription.id)
      end

      owed.where("indian_card_mandate_restart_notice_recorded_at < ?", cutoff).find_each do |subscription|
        expire_indian_card_mandate_restart_notices(subscription.id)
      end
    end

    def expire_indian_card_mandate_restart_notices(subscription_id)
      dropped = Subscription.find(subscription_id).expire_stale_indian_card_mandate_restart_notices!
      ErrorNotifier.notify("Dropped undelivered Indian card mandate restart notice past retention", **dropped) if dropped
    rescue StandardError => e
      ErrorNotifier.notify(e, subscription_id:)
    end
end
