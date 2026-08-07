# frozen_string_literal: true

class SendWorkflowEmailsToPastCanceledMembersJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, old_delayed_delivery_time = nil, cutoff_reference_time = nil)
    installment = Installment.find(installment_id)
    workflow = installment.workflow
    return unless workflow&.alive? && installment.alive? && installment.published?
    return unless workflow.member_cancellation_trigger?
    return unless workflow.seller_or_product_or_variant_type?

    rescheduling = old_delayed_delivery_time.present? && cutoff_reference_time.present?
    return unless workflow.send_to_past_customers? || rescheduling

    rule = installment.installment_rule
    return if rule.nil?

    delay = rule.delayed_delivery_time
    rule_version = rule.version
    cutoff = Time.zone.iso8601(cutoff_reference_time) if rescheduling

    candidate_subscriptions(workflow).includes(:original_purchase).find_each do |subscription|
      next unless subscription.cancelled?
      original_purchase = subscription.original_purchase
      next if original_purchase.nil?
      next unless workflow.applies_to_purchase?(original_purchase)

      if rescheduling
        reference_time = subscription.deactivated_at.change(usec: 0)
        next unless reference_time + old_delayed_delivery_time > cutoff

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
