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
      stuck_payment_states = %w(creating processing)
      stuck_payment_states << "unclaimed" if processor != PayoutProcessorType::STRIPE

      base_scope = Payment.where(processor:, state: stuck_payment_states)

      return base_scope if processor != PayoutProcessorType::STRIPE

      base_scope.where(
        "(state = 'creating' AND created_at < :creating_cutoff) OR " \
        "(state = 'processing' AND (" \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NOT NULL AND FROM_UNIXTIME(JSON_EXTRACT(json_data, '$.arrival_date')) < :today) OR " \
          "(JSON_EXTRACT(json_data, '$.arrival_date') IS NULL AND created_at < :processing_cutoff)" \
        "))",
        creating_cutoff: 24.hours.ago,
        today: Date.current,
        processing_cutoff: 3.days.ago
      )
    end
end
