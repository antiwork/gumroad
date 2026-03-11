# frozen_string_literal: true

class SyncStuckPayoutsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(processor)
    stuck_payments(processor).find_each do |payment|
      Rails.logger.info("Syncing #{processor} payout #{payment.id} stuck in #{payment.state} state")

      begin
        payment.sync_with_payout_processor
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
      # - "processing"/"unclaimed" past their expected arrival date (missed webhook)
      #   Uses stored arrival_date (unix timestamp) when available, falls back to
      #   created_at + 3 days for payouts without one (covers instant payouts too)
      base_scope.where(
        "(state = 'creating' AND created_at < :creating_cutoff) OR " \
        "(state IN ('processing', 'unclaimed') AND (" \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NOT NULL AND FROM_UNIXTIME(JSON_EXTRACT(json_data, '$.arrival_date')) < :now) OR " \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NULL AND created_at < :processing_cutoff)" \
        "))",
        creating_cutoff: 48.hours.ago,
        now: Time.current,
        processing_cutoff: 3.days.ago
      )
    end
end
