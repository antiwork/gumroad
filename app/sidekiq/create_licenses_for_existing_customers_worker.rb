# frozen_string_literal: true

class CreateLicensesForExistingCustomersWorker
  include Sidekiq::Job

  # One backfill per product at a time: a save that adds license-key blocks to several pages queues
  # one job per page, and overlapping runs would mint a second key for a purchase that already has one.
  sidekiq_options retry: 5, queue: :default, lock: :until_executed

  def perform(product_id)
    product = Link.find(product_id)

    product.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge.find_each do |purchase|
      # An archived original (replaced by a plan change) is not where the license is read from.
      if purchase.is_archived_original_subscription_purchase?
        next if purchase.license.present?

        purchase = purchase.subscription&.original_purchase
        next if purchase.nil?
      end

      # Skip purchases that shouldn't emit a license key — e.g. a variant whose
      # per-variant content doesn't embed a license-key block (free variants of
      # an otherwise licensed product).
      next unless purchase.variant_content_permits_license_key?

      License.where(link: product, purchase:).first_or_create!
    end
  end
end
