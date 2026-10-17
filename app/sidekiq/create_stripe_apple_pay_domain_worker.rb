# frozen_string_literal: true

# Registers a seller's own subdomain as a payment method domain, which Stripe requires before the
# wallet buttons (Apple Pay, Google Pay, Link) can render on their Gumroad pages. It is enqueued from
# User#after_save when the username changes — effectively once, at signup or first rename — and
# nothing re-runs it for that seller, so a failure here is permanent rather than transient.
class CreateStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # Exhausting the retries is the outcome nobody sees: the seller keeps a working storefront, just
  # without wallet buttons on it, and no stripe_apple_pay_domains row records why. Notify so a
  # permanently wallet-less account arrives as a support ticket rather than as an unexplained
  # checkout difference. (sentry-sidekiq is not in the bundle, so a job exception does not reach
  # Sentry on its own.)
  sidekiq_retries_exhausted do |msg, _exception|
    user_id, domain = msg["args"]
    ErrorNotifier.notify(
      "CreateStripeApplePayDomainWorker exhausted Sidekiq retries for user #{user_id} " \
      "(domain #{domain || "unknown"}): no stripe_apple_pay_domains row was written, so wallet " \
      "buttons will not render on that seller's Gumroad pages. Re-running the worker registers the " \
      "domain; see the dead job for the underlying Stripe error."
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
