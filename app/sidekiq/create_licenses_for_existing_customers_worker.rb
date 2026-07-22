# frozen_string_literal: true

class CreateLicensesForExistingCustomersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id)
    product = Link.find(product_id)

    product.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge.find_each do |purchase|
      # Skip purchases that shouldn't emit a license key — e.g. a variant whose
      # per-variant content doesn't embed a license-key block (free variants of
      # an otherwise licensed product).
      next unless purchase.variant_content_permits_license_key?

      License.where(link: product, purchase:).first_or_create!
    end
  end
end
