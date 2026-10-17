# frozen_string_literal: true

class DeleteStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Holds the row lock through the Stripe call so a create taking the host over waits for it.
  # Looked up by domain alone: that create may already have handed the row to the new holder.
  def perform(user_id, domain)
    StripeApplePayDomain.transaction do
      record = StripeApplePayDomain.lock.find_by(domain:)
      next unless record&.user_id == user_id

      response = Stripe::ApplePayDomain.delete(record.stripe_id)
      record.destroy if response.deleted
    rescue Stripe::InvalidRequestError
      record.destroy
    end
  end
end
