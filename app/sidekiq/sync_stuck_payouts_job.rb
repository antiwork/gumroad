# frozen_string_literal: true

class SyncStuckPayoutsJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform(processor)
    Payment.where(processor:, state: %w(creating processing unclaimed)).find_each do |payment|
      Rails.logger.info("Syncing payout #{payment.id} stuck in #{payment.state} state")

      begin
        payment.with_lock do
          payment.sync_with_payout_processor
        end
      rescue => e
        Rails.logger.error("Error syncing payout #{payment.id}: #{e.message}")
        next
      end

      Rails.logger.info("Payout #{payment.id} synced to #{payment.state} state")
    end
  end
end
