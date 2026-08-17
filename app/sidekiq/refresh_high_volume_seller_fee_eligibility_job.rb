# frozen_string_literal: true

# Recomputes the cached 30-day GMV flag used by the 5%-after-$20k fee.
# Per-seller on each successful sale; nightly with no args to drop sellers who fell below.
class RefreshHighVolumeSellerFeeEligibilityJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(seller_id = nil)
    if seller_id.present?
      User.find_by(id: seller_id)&.refresh_high_volume_fee_eligibility!
      return
    end

    seller_ids_to_refresh.each { |id| self.class.perform_async(id) }
  end

  private
    def seller_ids_to_refresh
      recent = Purchase.successful.where("created_at >= ?", 1.day.ago).distinct.pluck(:seller_id)
      flagged = User.where("json_data LIKE ?", "%high_volume_fee_eligible%true%").pluck(:id)
      (recent + flagged).uniq
    end
end
