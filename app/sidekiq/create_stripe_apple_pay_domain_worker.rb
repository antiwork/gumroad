# frozen_string_literal: true

class CreateStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # sentry-sidekiq is not in the bundle, so without this an exhausted job only reaches the log and
  # the dead set.
  sidekiq_retries_exhausted do |msg, _exception|
    user_id, domain = msg["args"]
    ErrorNotifier.notify(
      "CreateStripeApplePayDomainWorker exhausted Sidekiq retries for user #{user_id} " \
      "(domain #{domain || "unknown"}). Inspect the dead job for the error and the registration " \
      "state before retrying."
    )
  end

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
