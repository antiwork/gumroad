# frozen_string_literal: true

class SendWorkflowEmailsToPastCanceledMembersJob
  class RuleNotCommittedError < StandardError; end

  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, _old_delayed_delivery_time = nil, _cutoff_reference_time = nil, minimum_rule_version = nil)
    primary_pinned = minimum_rule_version.present?
    ActiveRecord::Base.connection.stick_to_primary! if primary_pinned
    installment = Installment.find(installment_id)
    workflow = installment.workflow
    return unless workflow&.alive? && installment.alive? && installment.published?
    return unless workflow.member_cancellation_trigger?
    return unless workflow.send_to_past_customers?
    return unless workflow.seller_or_product_or_variant_type?

    rule = installment.installment_rule
    return if rule.nil?
    raise RuleNotCommittedError if minimum_rule_version.present? && rule.version < minimum_rule_version
    cache_rule_version(rule)

    delay = rule.delayed_delivery_time
    rule_version = rule.version
    Makara::Context.release_all
    primary_pinned = false

    candidate_subscriptions(workflow).includes(:original_purchase).find_each do |subscription|
      next unless subscription.cancelled?
      original_purchase = subscription.original_purchase
      next if original_purchase.nil?
      next unless workflow.applies_to_purchase?(original_purchase)

      SendWorkflowInstallmentWorker.perform_at(
        subscription.deactivated_at + delay,
        installment.id, rule_version, nil, nil, nil, subscription.id
      )
    end
  ensure
    Makara::Context.release_all if primary_pinned
  end

  private
    def cache_rule_version(rule)
      rule.cache_version!
    rescue Redis::BaseError, RedisClient::Error => e
      ErrorNotifier.notify(e, installment_rule_id: rule.id)
    end

    def candidate_subscriptions(workflow)
      scope = Subscription.where.not(deactivated_at: nil).where.not(cancelled_at: nil)
      if workflow.product_or_variant_type?
        scope.where(link_id: workflow.link_id)
      else
        scope.where(seller_id: workflow.seller_id)
      end
    end
end
