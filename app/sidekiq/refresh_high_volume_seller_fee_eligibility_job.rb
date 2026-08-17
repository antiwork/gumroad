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
    # Threshold-crossers can only appear via new paid sales, but the per-sale hook can
    # be missed (dead job, flag ramped after the sales landed), so recompute the full
    # qualifying set from purchases each night instead of only yesterday's sellers.
    def seller_ids_to_refresh
      qualifying = Purchase.paid
        .where("purchases.created_at >= ?", User::HIGH_VOLUME_FEE_WINDOW.ago)
        .group(:seller_id)
        .having("SUM(purchases.price_cents) >= ?", User::HIGH_VOLUME_FEE_THRESHOLD_CENTS)
        .pluck(:seller_id)
      flagged = User.where("json_data LIKE ?", "%high_volume_fee_eligible%true%").pluck(:id)
      (qualifying + flagged).uniq
    end
end
