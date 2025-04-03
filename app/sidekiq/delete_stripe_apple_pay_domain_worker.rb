# frozen_string_literal: true

class DeleteStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(user_id, domain)
    record = StripeApplePayDomain.find_by(user_id:, domain:)
    return unless record
    response = Stripe::ApplePayDomain.delete(record.stripe_id)
    record.destroy if response.deleted
  rescue Stripe::InvalidRequestError
    record.destroy
  end
end
