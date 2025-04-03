# frozen_string_literal: true

class SyncStuckPurchasesJob
  include Sidekiq::Job
  sidekiq_options retry: 1, queue: :default, lock: :until_executed

  def perform
    purchase_creation_time_range = Range.new(3.days.ago, 4.hours.ago)

    Purchase.in_progress.created_between(purchase_creation_time_range).each do |purchase|
      next unless purchase.can_force_update?

      purchase.sync_status_with_charge_processor(mark_as_failed: true)

      next unless purchase.successful?

      if Purchase.successful
        .not_fully_refunded
        .not_chargedback_or_chargedback_reversed
        .where(link: purchase.link, email: purchase.email)
        .where("created_at > ?", purchase.created_at)
        .any? { |subsequent_purchase| subsequent_purchase.variant_attributes.pluck(:id).sort == purchase.variant_attributes.pluck(:id).sort }

        success = purchase.refund_and_save!(GUMROAD_ADMIN_ID)

        unless success
          Rails.logger.warn("SyncStuckPurchasesJob: Did not refund purchase with ID #{purchase.id}")
        end
      end
    end
  end
end
