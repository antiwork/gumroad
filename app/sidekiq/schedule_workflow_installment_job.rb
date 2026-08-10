# frozen_string_literal: true

class ScheduleWorkflowInstallmentJob
  class IntentNotCommittedError < StandardError; end
  class FanoutNotEnqueuedError < StandardError; end

  class ResubscriptionExclusionProbe
    def initialize(purchases:, seller_id:, excluded_sales:)
      @seller_id = seller_id
      @covered_emails = purchases.map(&:email).to_set
      matched_purchase_ids = Purchase.where(id: purchases.map(&:id), email: excluded_sales.select(:email)).ids.to_set
      nil_email_purchase_ids = purchases.filter_map { _1.id if _1.email.nil? }
      matched_purchase_ids.merge(nil_email_purchase_ids) if nil_email_purchase_ids.any? && excluded_sales.exists?(email: nil)
      @matched_emails = purchases.each_with_object(Set.new) do |purchase, emails|
        emails << purchase.email if matched_purchase_ids.include?(purchase.id)
      end
    end

    def covers?(email:, seller_id:)
      seller_id == @seller_id && @covered_emails.include?(email)
    end

    def matched?(seller_id:, email:, **)
      seller_id == @seller_id && @matched_emails.include?(email)
    end
  end
  private_constant :ResubscriptionExclusionProbe

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

      delay_edit_recovery = intent.old_delayed_delivery_time.present?
      if delay_edit_recovery
        reschedule_pending_resubscribed_memberships(
          installment,
          intent.old_delayed_delivery_time,
          intent.cutoff_reference_time
        )
      end
      result = workflow.schedule_installment(
        installment,
        old_delayed_delivery_time: intent.old_delayed_delivery_time,
        cutoff_reference_time: intent.cutoff_reference_time,
        reschedule_on_stale: delay_edit_recovery,
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

  private
    def reschedule_pending_resubscribed_memberships(installment, old_delayed_delivery_time, cutoff_reference_time)
      return if old_delayed_delivery_time.nil?

      workflow = installment.workflow
      return if workflow.member_cancellation_trigger?
      return unless workflow.seller_or_product_or_variant_type? || workflow.audience_type?

      restarted_after = cutoff_reference_time - old_delayed_delivery_time
      permalink_to_link_id, excluded_sales = resubscription_exclusion_context(workflow)
      candidate_subscriptions(workflow, restarted_after:)
        .preload(:subscription_events, original_purchase: [:link, :variant_attributes, :license, :subscription])
        .find_in_batches do |subscriptions|
        purchases = subscriptions.filter_map(&:original_purchase)
        seller_post_probe_batch = if excluded_sales && purchases.any?
          ResubscriptionExclusionProbe.new(purchases:, seller_id: workflow.seller_id, excluded_sales:)
        end

        subscriptions.each do |subscription|
          next unless subscription.alive?

          purchase = subscription.original_purchase
          next if purchase.nil? || !workflow.applies_to_purchase?(purchase, permalink_to_link_id:, seller_post_probe_batch:)

          restarted_at = latest_event_time(subscription.subscription_events, :restarted)
          deactivated_at = latest_event_time(subscription.subscription_events, :deactivated)
          next if restarted_at.nil? || deactivated_at.nil?

          reference_time = (purchase.created_at + (restarted_at - deactivated_at)).change(usec: 0)
          next if installment.is_for_new_customers_of_workflow && reference_time < installment.published_at
          next if reference_time + old_delayed_delivery_time <= cutoff_reference_time

          job_id = SendWorkflowInstallmentRescheduleJob.perform_at(
            reference_time + installment.installment_rule.delayed_delivery_time,
            installment.id,
            installment.installment_rule.version,
            purchase.id,
            nil,
            nil,
            nil,
            reference_time.iso8601
          )
          if job_id.blank?
            raise FanoutNotEnqueuedError, "Sidekiq did not enqueue the workflow installment"
          end
        end
      end
    end

    def resubscription_exclusion_context(workflow)
      permalink_to_link_id = if workflow.not_bought_products.present?
        Link.where(unique_permalink: workflow.not_bought_products).pluck(:unique_permalink, :id).to_h
      end
      exclude_product_ids = Array(workflow.not_bought_products).filter_map { permalink_to_link_id&.[](_1) }
      return [permalink_to_link_id, nil] if exclude_product_ids.empty? && workflow.not_bought_variants.blank?

      excluded_sales = Purchase.where(seller_id: workflow.seller_id)
                               .not_is_archived_original_subscription_purchase
                               .not_subscription_or_original_purchase
                               .by_external_variant_ids_or_products(workflow.not_bought_variants, exclude_product_ids)
      [permalink_to_link_id, excluded_sales]
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
