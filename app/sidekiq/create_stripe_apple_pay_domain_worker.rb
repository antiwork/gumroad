# frozen_string_literal: true

class CreateStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(user_id, domain = nil)
    return if Rails.env.test?

    user = User.find(user_id)
    domain ||= Subdomain.from_username(user.username)

    if domain && StripeApplePayDomain.find_by(user_id:, domain:).blank?
      response = Stripe::ApplePayDomain.create(domain_name: domain)
      if response
        StripeApplePayDomain.create(
          user_id:,
          domain:,
          stripe_id: response.id
        )
      end
    end
  end
end
