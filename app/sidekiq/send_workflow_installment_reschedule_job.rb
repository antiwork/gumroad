# frozen_string_literal: true

class SendWorkflowInstallmentRescheduleJob
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :low, lock: :until_executing

  def perform(installment_id, version, purchase_id, follower_id, affiliate_user_id, subscription_id, reschedule_reference_time)
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
