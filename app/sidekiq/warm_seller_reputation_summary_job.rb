# frozen_string_literal: true

class WarmSellerReputationSummaryJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :low, lock: :until_executed

  def perform(user_id)
    user = User.find_by(id: user_id)
    return unless user&.reputation_summary_enabled?

    user.warm_reputation_snapshot
  end
end
