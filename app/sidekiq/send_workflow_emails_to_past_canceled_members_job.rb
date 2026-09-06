# frozen_string_literal: true

class SendWorkflowEmailsToPastCanceledMembersJob
  class FanoutNotEnqueuedError < StandardError; end
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  include PrimaryDatabasePinning
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, old_delayed_delivery_time = nil, cutoff_reference_time = nil, minimum_rule_version = nil, schedule_intent_token = nil, schedule_intent_fanout_token = nil)
    @schedule_intent_token = schedule_intent_token
    @schedule_intent_fanout_token = schedule_intent_fanout_token
    rescheduling = old_delayed_delivery_time.present? && cutoff_reference_time.present?
    primary_pinned = minimum_rule_version.present? || schedule_intent_token.present? || schedule_intent_fanout_token.present? || rescheduling
    installment, workflow, rule = with_primary_database(primary_pinned) do
      return unless WorkflowInstallmentScheduleIntent.begin_fanout(
        intent_token: schedule_intent_token,
        fanout_token: schedule_intent_fanout_token
      )
      @next_fanout_heartbeat_at = fanout_heartbeat_time + WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f
      installment = Installment.find_by(id: installment_id)
      if installment.nil?
        WorkflowInstallmentScheduleIntent.mark_processed(
          schedule_intent_token,
          fanout_token: schedule_intent_fanout_token
        )
        return
      end
      workflow = installment.workflow
      unless workflow&.alive? && installment.alive? && installment.published? &&
             workflow.member_cancellation_trigger? &&
             (workflow.send_to_past_customers? || rescheduling) &&
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
      cache_rule_version(rule)
      [installment, workflow, rule]
    end

    # A reschedule must see cancellations committed alongside the new rule.
    with_primary_database(rescheduling) do
      delay = rule.delayed_delivery_time
      rule_version = rule.version
      cutoff = Time.zone.iso8601(cutoff_reference_time) if rescheduling
      deactivated_after = cutoff - old_delayed_delivery_time if rescheduling

      case enqueue_all_member_jobs(
        workflow:,
        installment:,
        delay:,
        rule_version:,
        rescheduling:,
        old_delayed_delivery_time:,
        cutoff:,
        deactivated_after:
      )
      when :complete
        WorkflowInstallmentScheduleIntent.mark_processed(
          schedule_intent_token,
          fanout_token: schedule_intent_fanout_token
        )
      when :ownership_lost
        nil
      else
        raise FanoutNotEnqueuedError, "Unexpected fanout result"
      end
    end
  end

  private
    def cache_rule_version(rule)
      rule.cache_version!
    rescue Redis::BaseError, RedisClient::Error => e
      ErrorNotifier.notify(e, installment_rule_id: rule.id)
    end

    def enqueue_all_member_jobs(workflow:, installment:, delay:, rule_version:, rescheduling:, old_delayed_delivery_time:, cutoff:, deactivated_after:)
      candidate_subscriptions(workflow, deactivated_after:).includes(:original_purchase).find_each do |subscription|
        return :ownership_lost unless renew_fanout_lease

        next unless subscription.cancelled?
        original_purchase = subscription.original_purchase
        next if original_purchase.nil?
        next unless workflow.applies_to_purchase?(original_purchase)

        job_id = if rescheduling
          reference_time = subscription.deactivated_at.change(usec: 0)
          next if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
          next unless reference_time + old_delayed_delivery_time > cutoff

          SendWorkflowInstallmentRescheduleJob.perform_at(
            reference_time + delay,
            installment.id, rule_version, nil, nil, nil, subscription.id, reference_time.iso8601
          )
        else
          SendWorkflowInstallmentWorker.perform_at(
            subscription.deactivated_at + delay,
            installment.id, rule_version, nil, nil, nil, subscription.id
          )
        end
        if job_id.blank?
          raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
        end
      end
      :complete
    end

    def renew_fanout_lease
      return true if @schedule_intent_token.blank? && @schedule_intent_fanout_token.blank?

      now = fanout_heartbeat_time
      return true if now < @next_fanout_heartbeat_at

      renewed = WorkflowInstallmentScheduleIntent.renew_fanout(
        intent_token: @schedule_intent_token,
        fanout_token: @schedule_intent_fanout_token
      )
      @next_fanout_heartbeat_at = now + WorkflowInstallmentScheduleIntent::FANOUT_HEARTBEAT_INTERVAL.to_f if renewed
      renewed
    end

    def fanout_heartbeat_time
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def candidate_subscriptions(workflow, deactivated_after: nil)
      scope = Subscription.where.not(deactivated_at: nil).where.not(cancelled_at: nil)
      scope = scope.where("subscriptions.deactivated_at > ?", deactivated_after) if deactivated_after.present?
      if workflow.product_or_variant_type?
        scope.where(link_id: workflow.link_id)
      else
        scope.where(seller_id: workflow.seller_id)
      end
    end
end
