# frozen_string_literal: true

class SyncStuckPayoutsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(processor)
    stuck_payments(processor).find_each do |payment|
      Rails.logger.info("Syncing #{processor} payout #{payment.id} stuck in #{payment.state} state")

      begin
        payment.with_lock do
          payment.sync_with_payout_processor
        end
      rescue => e
        Rails.logger.error("Error syncing #{processor} payout #{payment.id}: #{e.message}")
        next
      end

      Rails.logger.info("Payout #{payment.id} synced to #{payment.state} state")
    end
  end

  private
    def stuck_payments(processor)
      base_scope = Payment.where(processor:, state: %w(creating processing unclaimed))

      return base_scope unless processor == PayoutProcessorType::STRIPE

      # For Stripe: only sync payouts that are actually stuck
      # - "creating" for over 48 hours (never reached Stripe)
      # - "processing" past their expected arrival date (missed webhook)
      base_scope.where(
        "(state = 'creating' AND created_at < :creating_cutoff) OR " \
        "(state IN ('processing', 'unclaimed') AND created_at < :processing_cutoff)",
        creating_cutoff: 48.hours.ago,
        processing_cutoff: 3.days.ago
      )
    end
end
