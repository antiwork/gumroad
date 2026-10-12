# frozen_string_literal: true

class SyncStripeBusinessProfileUrlWorker
  include Sidekiq::Job
  sidekiq_options retry: 3, queue: :low

  def perform(user_id, old_username)
    user = User.find(user_id)
    merchant_account = user.stripe_account
    new_base = user.subdomain_with_protocol
    old_host = Subdomain.from_username(old_username)&.split(":")&.first
    return if merchant_account.blank? || new_base.blank? || old_host.blank?

    stripe_account = Stripe::Account.retrieve(merchant_account.charge_processor_merchant_id)
    current_url = stripe_account.business_profile&.url
    return if current_url.blank?

    uri = URI.parse(current_url)
    return unless uri.host&.casecmp?(old_host)

    new_uri = URI.parse(new_base)
    uri.host = new_uri.host
    uri.port = new_uri.port
    Stripe::Account.update(merchant_account.charge_processor_merchant_id, business_profile: { url: uri.to_s })
  rescue URI::InvalidURIError
    nil
  end
end
