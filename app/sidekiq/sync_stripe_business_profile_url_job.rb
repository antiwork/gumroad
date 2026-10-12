# frozen_string_literal: true

class SyncStripeBusinessProfileUrlJob
  include Sidekiq::Job
  sidekiq_options retry: 3,
                  queue: :low,
                  lock: :while_executing,
                  lock_timeout: 0,
                  lock_ttl: 10.minutes.to_i,
                  on_conflict: { server: :reschedule }

  def perform(user_id)
    user, merchant_account = ApplicationRecord.connected_to(role: :writing) do
      seller = User.find_by(id: user_id)
      [seller, seller&.stripe_account]
    end
    return if user.nil? || user.deleted? || user.subdomain.blank? || merchant_account.blank?

    stripe_account_id = merchant_account.charge_processor_merchant_id
    stripe_host = business_profile_host(Stripe::Account.retrieve(stripe_account_id))
    return unless stale_seller_subdomain?(stripe_host, user)

    Stripe::Account.update(stripe_account_id, business_profile: { url: user.business_profile_url })
  rescue Stripe::InvalidRequestError, Stripe::PermissionError => e
    Rails.logger.info("SyncStripeBusinessProfileUrlJob: skipped user #{user_id}: #{e.class}: #{e.message}")
  end

  private
    def business_profile_host(stripe_account)
      url = stripe_account.to_hash.dig(:business_profile, :url).to_s.strip
      return if url.blank?

      url = "https://#{url}" unless url.include?("://")
      URI.parse(url).host&.downcase
    rescue URI::InvalidURIError
      nil
    end

    def stale_seller_subdomain?(host, user)
      return false if host.blank?

      root_host = URI("#{PROTOCOL}://#{ROOT_DOMAIN}").host.downcase
      return false unless host.match?(/\A#{Subdomain::USERNAME_REGEXP.source}\.#{Regexp.escape(root_host)}\z/)
      return false if DENYLIST.include?(host.split(".").first)

      host != URI(user.subdomain_with_protocol).host.downcase
    end
end
