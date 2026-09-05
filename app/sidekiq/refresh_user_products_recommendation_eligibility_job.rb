# frozen_string_literal: true

class RefreshUserProductsRecommendationEligibilityJob
  include Sidekiq::Job
  # Runtime-only lock: until_and_while + client: :log dropped a mid-scan
  # follow-up; until_executing let an older Elasticsearch write finish after it.
  sidekiq_options retry: 3,
                  queue: :low,
                  lock: :while_executing,
                  lock_timeout: 0,
                  lock_ttl: 6.hours.to_i,
                  schedule_in: 1.minute.to_i,
                  on_conflict: { server: :reschedule }

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?

    user.products.find_each do |product|
      product.enqueue_index_update_for(%w[is_recommendable])
    end
  end
end
