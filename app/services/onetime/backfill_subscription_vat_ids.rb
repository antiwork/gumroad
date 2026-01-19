# frozen_string_literal: true

module Onetime
  class BackfillSubscriptionVatIds
    def self.process
      new.process
    end

    def process
      count = 0

      Subscription.where(business_vat_id: nil).find_each do |subscription|
        vat_id = subscription.resolve_vat_id
        next if vat_id.blank?

        subscription.update!(business_vat_id: vat_id)
        count += 1

        Rails.logger.info("Backfilled VAT ID for subscription #{subscription.id}")
        ReplicaLagWatcher.watch
      rescue StandardError => e
        Rails.logger.error("Failed to backfill VAT ID for subscription #{subscription.id}: #{e.message}")
      end

      Rails.logger.info("Backfilled VAT IDs for #{count} subscriptions")
      count
    end
  end
end
