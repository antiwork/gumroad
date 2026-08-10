# frozen_string_literal: true

class SendWorkflowInstallmentRescheduleJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id, subscription_id, reschedule_reference_time)
    return unless [purchase_id, follower_id, affiliate_user_id, subscription_id].one?(&:present?)

    SendWorkflowInstallmentWorker.new.perform(
      installment_id,
      version,
      purchase_id,
      follower_id,
      affiliate_user_id,
      subscription_id,
      reschedule_reference_time
    )
  end
end
