# frozen_string_literal: true

class ExpireRentalPurchasesWorker
  include Sidekiq::Job
  sidekiq_options retry: 0, queue: :default

  def perform
    Purchase.rentals_to_expire.find_each do |purchase|
      purchase.rental_expired = true
      purchase.save!
    end
  end
end
