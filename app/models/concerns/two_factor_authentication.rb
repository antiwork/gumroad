# frozen_string_literal: true

module TwoFactorAuthentication
  extend ActiveSupport::Concern

  DEFAULT_AUTH_TOKEN = "000000"

  TOKEN_VALIDITY = 10.minutes

  TWO_FACTOR_AUTH_EXPIRY = 2.months

  TWO_FACTOR_COOKIE_NAME_PREFIX = "_gumroad_two_factor_"

  class_methods do
    def find_by_encrypted_external_id(external_id)
      decrypted_external_id = ObfuscateIds.decrypt(external_id)
      find_by_external_id(decrypted_external_id)
    end
  end

  def encrypted_external_id
    ObfuscateIds.encrypt(external_id)
  end

  def two_factor_authentication_cookie_key
    # We set a unique cookie for each user in the browser to remember 2FA status for
    # multiple accounts from the same browser.
    #
    # The unique string we use in cookie name shouldn't be guessable. If we use user.external_id,
    # a scammer might be able to get that from public pages of that user. Here, we encrypt the external_id
    # using a cipher key known only to us which makes it unguessable.
    encrypted_id_sha = Digest::SHA256.hexdigest(encrypted_external_id)[0..12]

    "#{TWO_FACTOR_COOKIE_NAME_PREFIX}#{encrypted_id_sha}"
  end

  def send_authentication_token!
    email_provider = EmailRouterFallbackService.email_provider_for_two_factor(user: self)
    TwoFactorAuthenticationMailer.authentication_token(id, email_provider:).deliver_later(queue: "critical")
  end

  def add_two_factor_authenticated_ip!(remote_ip)
    two_factor_auth_redis_namespace.set(two_factor_auth_ip_redis_key(remote_ip), true, ex: TWO_FACTOR_AUTH_EXPIRY.to_i)
  end

  def token_authenticated?(authentication_token)
    return true if authenticate_otp(authentication_token, drift: TOKEN_VALIDITY).present?

    # Allow 000000 as valid authentication token in all non-production environments
    !Rails.env.production? && authentication_token == DEFAULT_AUTH_TOKEN
  end

  def has_logged_in_from_ip_before?(remote_ip)
    two_factor_auth_redis_namespace.get(two_factor_auth_ip_redis_key(remote_ip)).present?
  end

  def two_factor_auth_redis_namespace
    @two_factor_auth_redis_namespace ||= Redis::Namespace.new(:two_factor_auth_redis_namespace, redis: $redis)
  end

  private
    def two_factor_auth_ip_redis_key(remote_ip)
      "auth_ip_#{id}_#{remote_ip}"
    end
end
