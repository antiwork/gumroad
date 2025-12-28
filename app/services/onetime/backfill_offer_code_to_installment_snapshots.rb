# frozen_string_literal: true

module Onetime
  class BackfillOfferCodeToInstallmentSnapshots
    def self.perform
      updated_count = 0
      skipped_count = 0

      InstallmentPlanSnapshot.find_each do |snapshot|
        if snapshot.has_locked_offer_code?
          skipped_count += 1
          next
        end

        offer_code = find_offer_code_for_snapshot(snapshot)

        if offer_code
          snapshot.snapshot_offer_code!(offer_code)
          snapshot.save!
          updated_count += 1
          Rails.logger.info("Backfilled offer code #{offer_code.id} to snapshot #{snapshot.id}")
        else
          skipped_count += 1
        end
      rescue StandardError => e
        Rails.logger.error("Failed to backfill snapshot #{snapshot.id}: #{e.message}")
      end

      Rails.logger.info("Backfill complete: #{updated_count} updated, #{skipped_count} skipped")
      { updated: updated_count, skipped: skipped_count }
    end

    def self.find_offer_code_for_snapshot(snapshot)
      payment_option = snapshot.payment_option
      return nil if payment_option.nil?

      subscription = payment_option.subscription
      return nil if subscription.nil?

      original_purchase = subscription.original_purchase
      return nil if original_purchase.nil?

      original_purchase.offer_code
    end
  end
end
