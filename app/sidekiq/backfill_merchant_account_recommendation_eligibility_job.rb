# frozen_string_literal: true

# Enqueue once after deployment to repair product documents left by older account disconnects:
#   BackfillMerchantAccountRecommendationEligibilityJob.perform_async
class BackfillMerchantAccountRecommendationEligibilityJob
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low, lock: :until_executed, lock_ttl: 6.hours.to_i

  BATCH_SIZE = 500

  def perform
    disconnected_accounts.find_in_batches(batch_size: BATCH_SIZE) do |accounts|
      accounts.filter_map { |account| account.user_id if connected_payout_account?(account) }.uniq.each do |user_id|
        RefreshMerchantAccountProductsRecommendationEligibilityJob.perform_async(user_id)
      end
    end
  end

  private
    def disconnected_accounts
      MerchantAccount
        .where.not(user_id: nil)
        .where(charge_processor_id: [PaypalChargeProcessor.charge_processor_id, StripeChargeProcessor.charge_processor_id])
        .where("deleted_at IS NOT NULL OR charge_processor_deleted_at IS NOT NULL OR charge_processor_alive_at IS NULL")
    end

    def connected_payout_account?(account)
      return true if account.paypal_charge_processor?
      return false unless account.stripe_charge_processor?

      json_data = account[:json_data] || {}
      return true unless json_data.is_a?(Hash)

      json_data.dig("meta", "stripe_connect") == "true"
    end
end
