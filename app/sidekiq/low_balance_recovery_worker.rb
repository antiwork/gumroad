# frozen_string_literal: true

class LowBalanceRecoveryWorker
  include Sidekiq::Job
  sidekiq_options queue: :low, retry: 3

  def perform(user_id)
    User.find(user_id).check_for_probation_recovery!
  rescue ActiveRecord::RecordNotFound
    Rails.logger.warn("LowBalanceRecoveryWorker: User #{user_id} not found")
  end
end
