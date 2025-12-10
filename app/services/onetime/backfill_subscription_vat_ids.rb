# frozen_string_literal: true

module Onetime
  class BackfillSubscriptionVatIds
    def self.process
      new.process
    end

    def process
      count = 0

      Subscription.where(business_vat_id: nil).find_each do |subscription|
        vat_id = find_vat_id_for_subscription(subscription)
        next if vat_id.blank?

        subscription.update!(business_vat_id: vat_id)
        count += 1

        Rails.logger.info("Backfilled VAT ID for subscription #{subscription.id}")
        ReplicaLagWatcher.watch
      end

      Rails.logger.info("Backfilled VAT IDs for #{count} subscriptions")
      count
    end

    private

    def find_vat_id_for_subscription(subscription)
      vat_id = subscription.original_purchase&.purchase_sales_tax_info&.business_vat_id
      return vat_id if vat_id.present?

      subscription.send(:vat_id_from_any_subscription_purchase_refund)
    end
  end
end
