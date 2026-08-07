# frozen_string_literal: true

class SendWorkflowEmailsToPastCanceledMembersJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, old_delayed_delivery_time = nil, cutoff_reference_time = nil, minimum_rule_version = nil)
    primary_released = minimum_rule_version.blank? && cutoff_reference_time.blank?
    ActiveRecord::Base.connection.stick_to_primary! unless primary_released
    installment = Installment.find(installment_id)
    workflow = installment.workflow
    return unless workflow&.alive? && installment.alive? && installment.published?
    return unless workflow.member_cancellation_trigger?
    return unless workflow.seller_or_product_or_variant_type?

    rescheduling = cutoff_reference_time.present?
    new_installment = old_delayed_delivery_time.nil? && rescheduling
    return unless workflow.send_to_past_customers? || rescheduling

    rule = installment.installment_rule
    return if rule.nil?
    raise RuleNotCommittedError if minimum_rule_version.present? && rule.version < minimum_rule_version
    rule.cache_version!

    delay = rule.delayed_delivery_time
    rule_version = rule.version
    cutoff = Time.zone.iso8601(cutoff_reference_time) if rescheduling
    unless rescheduling
      Makara::Context.release_all
      primary_released = true
    end

    candidate_subscriptions(workflow).includes(:original_purchase).find_each do |subscription|
      next unless subscription.cancelled?
      original_purchase = subscription.original_purchase
      next if original_purchase.nil?
      next unless workflow.applies_to_purchase?(original_purchase)

      if rescheduling
        reference_time = subscription.deactivated_at.change(usec: 0)
        next if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
        next unless new_installment || reference_time + old_delayed_delivery_time > cutoff

        SendWorkflowInstallmentRescheduleJob.perform_at(
          reference_time + delay,
          installment.id, rule_version, nil, nil, nil, subscription.id, reference_time.iso8601
        )
        next
      end

      SendWorkflowInstallmentWorker.perform_at(
        subscription.deactivated_at + delay,
        installment.id, rule_version, nil, nil, nil, subscription.id
      )
    end
  ensure
    Makara::Context.release_all unless primary_released
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
