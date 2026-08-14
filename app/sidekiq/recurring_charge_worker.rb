# frozen_string_literal: true

class RecurringChargeWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(subscription_id, ignore_consecutive_failures = false, _deprecated = nil)
    ActiveRecord::Base.connection.stick_to_primary!
    SuoSemaphore.recurring_charge(subscription_id).lock do
      Rails.logger.info("Processing RecurringChargeWorker#perform(#{subscription_id})")
      subscription = Subscription.find(subscription_id)
      return if subscription.link.user.suspended?
      return unless subscription.alive?(include_pending_cancellation: false)
      if subscription.india_card_mandate_reliability_enabled? && subscription.renewal_disabled_due_to_indian_card_mandate?
        # Keep access active while the charge waits for a mandate that Stripe can use.
        return unless subscription.refresh_indian_card_mandate! == "active"
      end
      return if subscription.is_test_subscription || subscription.current_subscription_price_cents == 0
      return if subscription.charges_completed?
      # An installment plan whose every prior installment was charged back cannot be cancelled
      # (see Subscription#all_charges_disputed?), so without this guard it keeps its schedule and
      # charges the disputing buyer again. Placed before in_free_trial? so it applies regardless of
      # trial state, and returns rather than failing the subscription: a reversed chargeback should
      # let the plan resume by itself on the next tick.
      if subscription.all_charges_disputed?
        Rails.logger.info(
          "RecurringChargeWorker#perform(#{subscription_id}): skipping charge, " \
          "installment plan has a standing chargeback on every installment"
        )
        return
      end
      return if subscription.in_free_trial?
      last_successful_purchase = subscription.purchases.successful.last
      return if last_successful_purchase && (last_successful_purchase.created_at + subscription.period) > Time.current

      last_purchase = subscription.purchases.last

      return if last_purchase.in_progress? && last_purchase.sync_status_with_charge_processor
      return if subscription.has_a_charge_in_progress?
      if ignore_consecutive_failures && last_purchase.failed?
        if subscription.seconds_overdue_for_charge > Subscription::ALLOWED_TIME_BEFORE_FAIL_AND_UNSUBSCRIBE
          Rails.logger.info("RecurringChargeWorker#perform(#{subscription_id}): marking subscription failed")
          subscription.unsubscribe_and_fail!
        end
        return
      end

      # Check if the user has initiated any plan changes that must be applied at
      # the end of the current billing period. If so, apply the most recent change
      # before charging.
      plan_changes = subscription.subscription_plan_changes.alive
      latest_applicable_plan_change = subscription.latest_applicable_plan_change
      check_mandate_terms_after_plan_change = latest_applicable_plan_change.present? &&
        subscription.india_card_mandate_reliability_enabled? &&
        subscription.credit_card_to_charge&.requires_mandate?
      mandate_terms_before_plan_change = if check_mandate_terms_after_plan_change
        subscription.indian_card_mandate_terms
      end
      override_params = {}
      if latest_applicable_plan_change.present?
        same_tier = latest_applicable_plan_change.tier == subscription.tier
        new_price = subscription.link.prices.is_buy.alive.find_by(recurrence: latest_applicable_plan_change.recurrence) ||
          subscription.link.prices.is_buy.find_by(recurrence: latest_applicable_plan_change.recurrence) # use live price if exists, else deleted price
        begin
          subscription.update_current_plan!(
            new_variants: [latest_applicable_plan_change.tier],
            new_price:,
            new_quantity: latest_applicable_plan_change.quantity,
            perceived_price_cents: latest_applicable_plan_change.perceived_price_cents,
            is_applying_plan_change: true,
          )
          latest_applicable_plan_change.update!(applied: true)
        rescue Subscription::UpdateFailed => e
          Rails.logger.info("RecurringChargeWorker#perform(#{subscription_id}) failed: #{e.class} (#{e.message})")
          return
        end
        subscription.reload.original_purchase.schedule_workflows_for_variants unless same_tier
        plan_changes.map(&:mark_deleted!)
        override_params[:is_upgrade_purchase] = true # avoid double charged error
        subscription.reload

        UpdateIntegrationsOnTierChangeWorker.perform_async(subscription.id) unless same_tier

        if check_mandate_terms_after_plan_change &&
           subscription.indian_card_mandate_terms != mandate_terms_before_plan_change
          subscription.require_indian_card_mandate_reauthorization!
          return
        end
      end

      subscription.charge!(override_params:)
      Rails.logger.info("Completed processing RecurringChargeWorker#perform(#{subscription_id})")
    end
  end
end
