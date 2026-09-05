# frozen_string_literal: true

class RefreshUserProductsRecommendationEligibilityJob
  include Sidekiq::Job
  # lock: :until_executing so a bank-account transition during a scan can
  # enqueue a follow-up. :until_and_while_executing + client: :log dropped
  # that follow-up and left mixed is_recommendable values.
  sidekiq_options retry: 3,
                  queue: :low,
                  lock: :until_executing,
                  lock_ttl: 6.hours.to_i,
                  on_conflict: { client: :log }

  def perform(user_id)
    user = User.find_by(id: user_id)
    return if user.nil?

    user.products.find_each do |product|
      product.enqueue_index_update_for(%w[is_recommendable])
    end
  end
end
