# frozen_string_literal: true

# Registers a seller's own subdomain with Stripe, which wallet buttons (Apple Pay, Google Pay, Link)
# need before they render on that seller's pages.
class CreateStripeApplePayDomainWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  # sentry-sidekiq is not in the bundle, so an exhausted job is otherwise silent while the seller
  # quietly loses wallet buttons.
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
    return if domain.blank?

    return if claim_existing_registration(user_id, domain)

    response = Stripe::ApplePayDomain.create(domain_name: domain)
    return unless response

    StripeApplePayDomain.create(
      user_id:,
      domain:,
      stripe_id: response.id
    )
  rescue ActiveRecord::RecordNotUnique
    # A concurrent create inserted first. Claim its row, or retry if it is gone here or on Stripe.
    raise unless claim_existing_registration(user_id, domain)
  end

  private
    # The row lock serializes with a delete queued or running for the username's previous holder.
    # Commits before returning false: two creates holding an empty lookup's gap lock across the
    # Stripe call would deadlock on their inserts.
    def claim_existing_registration(user_id, domain)
      StripeApplePayDomain.transaction do
        existing = StripeApplePayDomain.lock.find_by(domain:)
        next false if existing.nil?
        next true if existing.user_id == user_id

        # The previous holder's delete can reach Stripe and still fail with every response lost.
        if registration_missing_on_stripe?(existing.stripe_id)
          existing.destroy!
          next false
        end
        existing.update!(user_id:)
        true
      end
    end

    def registration_missing_on_stripe?(stripe_id)
      Stripe::ApplePayDomain.retrieve(stripe_id)
      false
    rescue Stripe::InvalidRequestError => e
      raise unless e.code == "resource_missing"
      true
    end
end
