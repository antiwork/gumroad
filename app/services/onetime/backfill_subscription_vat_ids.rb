# frozen_string_literal: true

module Onetime
  class BackfillSubscriptionVatIds
    def self.process(batch_size: 1000, dry_run: false)
      new(batch_size:, dry_run:).process
    end

    def initialize(batch_size: 1000, dry_run: false)
      @batch_size = batch_size
      @dry_run = dry_run
      @stats = { processed: 0, updated: 0, skipped: 0, errors: 0 }
    end

    def process
      Rails.logger.info("[BackfillSubscriptionVatIds] Starting backfill (dry_run: #{@dry_run})")

      Subscription.where(business_vat_id: nil).find_each(batch_size: @batch_size) do |subscription|
        process_subscription(subscription)
      end

      log_final_stats
      @stats
    end

    private

    def process_subscription(subscription)
      @stats[:processed] += 1

      vat_id = subscription.resolve_vat_id
      if vat_id.blank?
        @stats[:skipped] += 1
        return
      end

      if @dry_run
        Rails.logger.info("[BackfillSubscriptionVatIds] Would update subscription #{subscription.id} with VAT ID: #{vat_id}")
        @stats[:updated] += 1
        return
      end

      subscription.update!(business_vat_id: vat_id)
      @stats[:updated] += 1
      Rails.logger.info("[BackfillSubscriptionVatIds] Updated subscription #{subscription.id} with VAT ID: #{vat_id}")
      ReplicaLagWatcher.watch
    rescue StandardError => e
      @stats[:errors] += 1
      Rails.logger.error("[BackfillSubscriptionVatIds] Failed to update subscription #{subscription.id}: #{e.message}")
    end

    def log_final_stats
      Rails.logger.info(
        "[BackfillSubscriptionVatIds] Complete. " \
        "Processed: #{@stats[:processed]}, " \
        "Updated: #{@stats[:updated]}, " \
        "Skipped: #{@stats[:skipped]}, " \
        "Errors: #{@stats[:errors]}"
      )
    end
  end
end
