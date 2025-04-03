# frozen_string_literal: true

class SendWorkflowInstallmentWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id = nil, subscription_id = nil)
    installment = Installment.find_by(id: installment_id)

    return if installment.nil?
    return if installment.seller&.suspended?
    return unless installment.workflow.alive?
    return unless installment.alive?
    return unless installment.published?

    installment_rule = installment.installment_rule
    return if installment_rule.nil?
    return if installment_rule.version != version

    if purchase_id.present? && follower_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_purchase(purchase_id)
    elsif follower_id.present? && purchase_id.nil? && affiliate_user_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_follower(follower_id)
    elsif affiliate_user_id.present? && purchase_id.nil? && follower_id.nil? && subscription_id.nil?
      installment.send_installment_from_workflow_for_affiliate_user(affiliate_user_id)
    elsif subscription_id.present? && purchase_id.nil? && follower_id.nil? && affiliate_user_id.nil?
      installment.send_installment_from_workflow_for_member_cancellation(subscription_id)
    end
  end
end
