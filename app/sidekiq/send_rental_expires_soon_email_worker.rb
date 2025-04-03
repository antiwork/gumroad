# frozen_string_literal: true

class SendRentalExpiresSoonEmailWorker
  include Sidekiq::Job
  sidekiq_options retry: 5, queue: :default

  def perform(purchase_id, time_till_rental_expiration_in_seconds)
    purchase = Purchase.find(purchase_id)
    url_redirect = purchase.url_redirect
    return if !url_redirect.is_rental || url_redirect.rental_first_viewed_at.present? || purchase.chargedback_not_reversed_or_refunded?

    CustomerLowPriorityMailer.rental_expiring_soon(purchase.id, time_till_rental_expiration_in_seconds).deliver_later(queue: "low")
  end
end
