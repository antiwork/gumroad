# frozen_string_literal: true

class ScheduleWorkflowInstallmentJob
  class IntentNotCommittedError < StandardError; end
  class FanoutNotEnqueuedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 10, queue: :low

  def perform(intent_token, dispatch_token = nil)
    ActiveRecord::Base.connection.stick_to_primary!
    WorkflowInstallmentScheduleIntent.transaction do
      intent = WorkflowInstallmentScheduleIntent.lock.find_by(token: intent_token)
      next if intent.nil?
      next if intent.processed_at.present?
      if dispatch_token.present? && intent.dispatch_token != dispatch_token
        now = Time.current
        another_dispatch_active = intent.dispatch_token.present? &&
                                  intent.dispatch_expires_at.present? &&
                                  intent.dispatch_expires_at > now
        fanout_active = intent.fanout_token.present? &&
                        intent.fanout_expires_at.present? &&
                        intent.fanout_expires_at > now
        raise IntentNotCommittedError unless another_dispatch_active || fanout_active

        next
      end

      installment = Installment.find_by(id: intent.installment_id)
      if installment.nil? || installment.installment_rule.nil?
        intent.mark_processed!
        next
      end

      current_version = installment.installment_rule.version
      raise IntentNotCommittedError if current_version < intent.rule_version

      workflow = installment.workflow
      if workflow.nil?
        intent.mark_processed!
        next
      end

      if intent.expected_published_at.present?
        publication_matches = false
        workflow.with_lock do
          installment.reload
          publication_matches = workflow.published_at&.change(usec: 0) == intent.expected_published_at &&
                                installment.published_at&.change(usec: 0) == intent.expected_published_at
        end
        unless publication_matches
          intent.mark_processed!
          next
        end
      end
      unless workflow.alive? && installment.alive? && installment.published?
        intent.mark_processed!
        next
      end

      fanout_token = intent.claim_fanout!
      next if fanout_token.nil?

      result = workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: intent.old_delayed_delivery_time,
        cutoff_reference_time: intent.cutoff_reference_time,
        minimum_rule_version: current_version,
        schedule_intent_token: intent.token,
        schedule_intent_fanout_token: fanout_token
      )
      case result
      when :enqueued
        next
      when :not_applicable
        intent.mark_processed!
      when :not_enqueued
        raise FanoutNotEnqueuedError, "Recipient fanout was not enqueued"
      else
        raise FanoutNotEnqueuedError, "Unexpected schedule result: #{result.inspect}"
      end
    end
  ensure
    Makara::Context.release_all
  end
end
