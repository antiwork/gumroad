# frozen_string_literal: true

class ScheduleWorkflowInstallmentJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :low

  def perform(installment_id, rule_version, old_delayed_delivery_time, cutoff_reference_time)
    ActiveRecord::Base.connection.stick_to_primary!
    installment = Installment.find_by(id: installment_id)
    raise RuleNotCommittedError if installment.nil? || installment.installment_rule.nil?

    current_version = installment.installment_rule.version
    raise RuleNotCommittedError if current_version < rule_version
    return unless installment.workflow.alive? && installment.alive? && installment.published?

    # An older rule can own a wider recipient window. Preserve that window when a newer
    # rule commits first; SentPostEmail's unique key prevents duplicate delivery.
    cutoff_reference_time = Time.zone.iso8601(cutoff_reference_time)
    installment.workflow.schedule_installment(
      installment,
      old_delayed_delivery_time:,
      cutoff_reference_time:,
      reschedule_on_stale: true,
      minimum_rule_version: current_version
    )
    Makara::Context.release_all
    reschedule_pending_resubscribed_memberships(installment, old_delayed_delivery_time, cutoff_reference_time)
  end

  private
    def reschedule_pending_resubscribed_memberships(installment, old_delayed_delivery_time, cutoff_reference_time)
      workflow = installment.workflow
      return if old_delayed_delivery_time.nil? || workflow.member_cancellation_trigger?
      return unless workflow.seller_or_product_or_variant_type? || workflow.audience_type?

      restarted_after = cutoff_reference_time - old_delayed_delivery_time
      candidate_subscriptions(workflow, restarted_after:).preload(:original_purchase, :subscription_events).find_each do |subscription|
        next unless subscription.alive?

        purchase = subscription.original_purchase
        next if purchase.nil? || !workflow.applies_to_purchase?(purchase)

        restarted_at = latest_event_time(subscription.subscription_events, :restarted)
        deactivated_at = latest_event_time(subscription.subscription_events, :deactivated)
        next if restarted_at.nil? || deactivated_at.nil?

        reference_time = (purchase.created_at + (restarted_at - deactivated_at)).change(usec: 0)
        next if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
        next unless reference_time + old_delayed_delivery_time > cutoff_reference_time

        SendWorkflowInstallmentRescheduleJob.perform_at(
          reference_time + installment.installment_rule.delayed_delivery_time,
          installment.id,
          installment.installment_rule.version,
          purchase.id,
          nil,
          nil,
          nil,
          reference_time.iso8601
        )
      end
    end

    def latest_event_time(events, event_type)
      events.select { _1.event_type == event_type.to_s }
            .max_by { [_1.occurred_at, _1.id] }
            &.occurred_at
    end

    def candidate_subscriptions(workflow, restarted_after:)
      scope = Subscription.joins(:subscription_events)
                          .where(subscriptions: { seller_id: workflow.seller_id })
                          .where(subscription_events: { event_type: SubscriptionEvent.event_types[:restarted] })
                          .where("subscription_events.occurred_at > ?", restarted_after)
                          .distinct
      if workflow.product_or_variant_type?
        scope.where(link_id: workflow.link_id)
      else
        scope.where(seller_id: workflow.seller_id)
      end
    end
end
