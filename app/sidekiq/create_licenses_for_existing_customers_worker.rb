# frozen_string_literal: true

class CreateLicensesForExistingCustomersWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(product_id)
    product = Link.find(product_id)

    product.sales.successful_gift_or_nongift.not_is_gift_sender_purchase.not_recurring_charge.find_each do |purchase|
      License.where(link: product, purchase:).first_or_create!
    end
  end
end
