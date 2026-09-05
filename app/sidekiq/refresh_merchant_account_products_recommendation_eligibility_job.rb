# frozen_string_literal: true

class RefreshMerchantAccountProductsRecommendationEligibilityJob
  include Sidekiq::Job
  # Follow-up scans must remain enqueueable and cannot overtake the scan already running.
  sidekiq_options retry: 3,
                  queue: :low,
                  lock: :until_and_while_executing,
                  lock_ttl: 6.hours.to_i,
                  on_conflict: { client: :log, server: :reschedule }

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?

    user.products.find_each do |product|
      product.enqueue_index_update_for(%w[is_recommendable])
    end
  end
end
