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

    # A row outlives the account that wrote it: a deleted account's is never removed, and a renamed
    # one is still queued for deletion when a later signup takes the freed username. Hand it over so
    # that pending delete finds no row instead of taking the host's wallet buttons with it.
    existing = StripeApplePayDomain.find_by(domain:)
    if existing
      existing.update!(user_id:) if existing.user_id != user_id
      return
    end

    response = Stripe::ApplePayDomain.create(domain_name: domain)
    return unless response

    StripeApplePayDomain.create(
      user_id:,
      domain:,
      stripe_id: response.id
    )
  rescue ActiveRecord::RecordNotUnique
    # Two accounts on the same host registered at once; the row the other worker wrote covers both.
  end
end
