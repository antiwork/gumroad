# frozen_string_literal: true

# Single-use server-issued nonces for the Apple App Attest flow used by the
# Gumroad Walks iOS app. The iOS client GETs a fresh challenge before every
# attestation/assertion and hashes it (together with the request body, on
# assertions) into the clientDataHash that DCAppAttestService signs over.
#
# Stored in Rails.cache (Redis) because:
#  - The data is ephemeral (5-minute TTL).
#  - We don't want this hot, short-lived churn on MySQL.
#  - `delete` is the atomic consume primitive we need for single-use.
class WalksAppAttestChallenge
  TTL = 5.minutes
  PREFIX = "walks:app_attest:chal:"

  class << self
    def issue!
      SecureRandom.urlsafe_base64(32).tap do |challenge|
        Rails.cache.write(cache_key(challenge), "1", expires_in: TTL)
      end
    end

    # Returns true if the challenge existed and was deleted (single-use), false
    # otherwise. Treats blank input as miss.
    def consume!(challenge)
      return false if challenge.blank?
      !!Rails.cache.delete(cache_key(challenge))
    end

    private
      def cache_key(challenge)
        "#{PREFIX}#{challenge}"
      end
  end
end
