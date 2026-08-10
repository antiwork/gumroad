# frozen_string_literal: true

class SendWorkflowEmailsToPastCanceledMembersJob
  class FanoutNotEnqueuedError < StandardError; end
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, _old_delayed_delivery_time = nil, _cutoff_reference_time = nil, minimum_rule_version = nil, schedule_intent_token = nil, schedule_intent_fanout_token = nil)
    primary_pinned = minimum_rule_version.present? || schedule_intent_token.present?
    ActiveRecord::Base.connection.stick_to_primary! if primary_pinned
    return unless WorkflowInstallmentScheduleIntent.begin_fanout(
      intent_token: schedule_intent_token,
      fanout_token: schedule_intent_fanout_token
    )
    installment = Installment.find(installment_id)
    workflow = installment.workflow
    unless workflow&.alive? && installment.alive? && installment.published? &&
           workflow.member_cancellation_trigger? && workflow.send_to_past_customers? &&
           workflow.seller_or_product_or_variant_type?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end

    rule = installment.installment_rule
    if rule.nil?
      WorkflowInstallmentScheduleIntent.mark_processed(
        schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      return
    end
    raise RuleNotCommittedError if minimum_rule_version.present? && rule.version < minimum_rule_version
    rule.cache_version!

    delay = rule.delayed_delivery_time
    rule_version = rule.version
    Makara::Context.release_all
    primary_pinned = false

    candidate_subscriptions(workflow).includes(:original_purchase).find_each do |subscription|
      next unless subscription.cancelled?
      original_purchase = subscription.original_purchase
      next if original_purchase.nil?
      next unless workflow.applies_to_purchase?(original_purchase)

      job_id = SendWorkflowInstallmentWorker.perform_at(
        subscription.deactivated_at + delay,
        installment.id, rule_version, nil, nil, nil, subscription.id
      )
      if job_id.blank?
        raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
      end
    end
    WorkflowInstallmentScheduleIntent.mark_processed(
      schedule_intent_token,
      fanout_token: schedule_intent_fanout_token
    )
  ensure
    Makara::Context.release_all if primary_pinned
  end

  private
    def candidate_subscriptions(workflow)
      scope = Subscription.where.not(deactivated_at: nil).where.not(cancelled_at: nil)
      if workflow.product_or_variant_type?
        scope.where(link_id: workflow.link_id)
      else
        scope.where(seller_id: workflow.seller_id)
      end
    end
end
