# frozen_string_literal: true

# Single-use server-issued nonces for the Apple App Attest flow used by the
# Gumroad Walks iOS app. The iOS client GETs a fresh challenge before every
# attestation/assertion and hashes it (together with the request body, on
# assertions) into the clientDataHash that DCAppAttestService signs over.
#
# Stored in `$redis` (not Rails.cache, which is Memcached in production and can
# evict keys before their TTL under memory pressure — a dropped challenge fails
# the request as `invalid_challenge`). `$redis` is the same store the analogous
# single-use ACME challenge tokens use. `SETEX` issues the nonce; `DEL`'s
# return value (1 iff the key existed) is the atomic consume primitive that
# guarantees single-use even under concurrent requests.
class WalksAppAttestChallenge
  TTL = 5.minutes

  class << self
    def issue!
      SecureRandom.urlsafe_base64(32).tap do |challenge|
        $redis.setex(RedisKey.walks_app_attest_challenge(challenge), TTL.to_i, "1")
      end
    end

    # Returns true if the challenge existed and was deleted (single-use), false
    # otherwise. `DEL` returns the number of keys it removed, so a positive
    # count means this caller is the one that consumed the nonce. Treats blank
    # input as a miss.
    def consume!(challenge)
      return false if challenge.blank?
      deleted_count = $redis.del(RedisKey.walks_app_attest_challenge(challenge))
      deleted_count.positive?
    end
  end
end
