# frozen_string_literal: true

class SendWorkflowInstallmentWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id = nil, subscription_id = nil, reschedule_reference_time = nil)
    installment = Installment.find_by(id: installment_id)

    return if installment.nil?
    return if installment.seller&.suspended?
    return unless installment.workflow.alive?
    return unless installment.alive?
    return unless installment.published?

    installment_rule = installment.installment_rule
    return if installment_rule.nil?
    if reschedule_reference_time.present?
      return unless recipient_matches_current_audience?(
        installment:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:,
        reschedule_reference_time:
      )
    end
    if installment_rule.version != version
      reschedule_with_current_rule(
        installment:,
        installment_rule:,
        version:,
        purchase_id:,
        follower_id:,
        affiliate_user_id:,
        subscription_id:,
        reschedule_reference_time:
      )
      return
    end

    if purchase_id.present? && follower_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_purchase(purchase_id, reschedule_reference_time:)
    elsif follower_id.present? && purchase_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_follower(follower_id)
    elsif affiliate_user_id.present? && purchase_id.nil? && follower_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_affiliate_user(affiliate_user_id)
    elsif subscription_id.present? && purchase_id.nil? && follower_id.nil? && affiliate_user_id.nil?
      installment.send_installment_from_workflow_for_member_cancellation(subscription_id)
    else
      # Exactly one recipient id is expected. Anything else (most importantly all four nil)
      # used to fall through and return without sending, erroring, or retrying, which is how
      # a whole class of workflows could deliver nothing at all without anyone noticing.
      Rails.logger.error("[#{self.class.name}] installment_id=#{installment_id} got an unusable recipient combination (purchase=#{purchase_id.inspect} follower=#{follower_id.inspect} affiliate=#{affiliate_user_id.inspect} subscription=#{subscription_id.inspect}); nothing sent")
    end
  end

  private
    def reschedule_with_current_rule(installment:, installment_rule:, version:, purchase_id:, follower_id:, affiliate_user_id:, subscription_id:, reschedule_reference_time:)
      return if reschedule_reference_time.nil? || installment_rule.version < version

      # Carry the recipient across consecutive rule changes instead of dropping the older window.
      deliver_at = Time.zone.iso8601(reschedule_reference_time) + installment_rule.delayed_delivery_time
      SendWorkflowInstallmentRescheduleJob.perform_at(
        deliver_at,
        installment.id,
        installment_rule.version,
        purchase_id,
        follower_id,
        affiliate_user_id,
        subscription_id,
        reschedule_reference_time
      )
    end

    def recipient_matches_current_audience?(installment:, purchase_id:, follower_id:, affiliate_user_id:, subscription_id:, reschedule_reference_time:)
      recipient_ids = [purchase_id, follower_id, affiliate_user_id, subscription_id]
      return false unless recipient_ids.one?(&:present?)

      reference_time = Time.zone.iso8601(reschedule_reference_time)
      if subscription_id.present?
        subscription = Subscription.find_by(id: subscription_id)
        return false if subscription.nil? || subscription.alive?

        purchase = subscription.original_purchase
        return false if purchase.nil? || subscription.deactivated_at.nil?
        return false if SentPostEmail.exists?(post: installment, email: purchase.email)
        return false if installment.workflow.present? && !installment.workflow.applies_to_purchase?(purchase)

        return subscription.deactivated_at.change(usec: 0) == reference_time
      end

      purchase = Purchase.find_by(id: purchase_id)&.original_purchase if purchase_id.present?
      email = if purchase.present?
        purchase.email
      elsif follower_id.present?
        Follower.where(id: follower_id).pick(:email)
      elsif affiliate_user_id.present?
        User.where(id: affiliate_user_id).pick(:email)
      end
      return false if email.nil?
      return false if SentPostEmail.exists?(post: installment, email:)

      member = AudienceMember.find_by(seller_id: installment.seller_id, email: email.downcase)
      return false if member.nil?

      current_match = AudienceMember.filter(
        seller_id: installment.seller_id,
        params: installment.audience_members_filter_params,
        with_ids: true,
        ids: [member.id]
      ).first
      return false if current_match.nil?
      if purchase.present?
        purchase_is_current = member.details.fetch("purchases", []).any? { _1["id"] == purchase.id }
        return false unless purchase_is_current && installment.workflow.applies_to_purchase?(purchase)

        valid_reference_times = [
          purchase.created_at.change(usec: 0),
          installment.workflow_delivery_reference_time(purchase).change(usec: 0),
        ]
        return valid_reference_times.include?(reference_time)
      end
      return current_match.follower_id == follower_id if follower_id.present?
      if affiliate_user_id.present?
        return false if current_match.affiliate_id.nil?

        affiliate = DirectAffiliate.alive.find_by(id: current_match.affiliate_id, affiliate_user_id:)
        return false if affiliate.nil?

        return affiliate.created_at.change(usec: 0) == reference_time
      end

      true
    end
end
